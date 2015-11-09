module d.semantic.symbol;

import d.semantic.caster;
import d.semantic.declaration;
import d.semantic.semantic;

import d.ast.declaration;
import d.ast.expression;
import d.ast.identifier;

import d.ir.dscope;
import d.ir.expression;
import d.ir.symbol;
import d.ir.type;

// TODO: change ast to allow any statement as function body, then remove that import.
import d.ast.statement;

alias AstModule = d.ast.declaration.Module;
alias Module = d.ir.symbol.Module;

alias BinaryExpression = d.ir.expression.BinaryExpression;

// Conflict with Interface in object.di
alias Interface = d.ir.symbol.Interface;

enum isSchedulable(D, S) = is(D : Declaration) && is(S : Symbol) && !__traits(isAbstractClass, S);

struct SymbolVisitor {
	private SemanticPass pass;
	alias pass this;

	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	void visit(Declaration d, Symbol s) {
		auto tid = typeid(s);
		
		import std.traits, std.typetuple;
		alias Members = TypeTuple!(__traits(getOverloads, SymbolAnalyzer, "analyze"));
		foreach(visit; Members) {
			alias parameters = ParameterTypeTuple!visit;
			static assert(parameters.length == 2);
			
			static if(isSchedulable!parameters) {
				alias DeclType = parameters[0];
				alias SymType  = parameters[1];
				
				if (tid is typeid(SymType)) {
					auto decl = cast(DeclType) d;
					assert(decl, "Unexpected declaration type " ~ typeid(DeclType).toString());
					
					scheduler.schedule(decl, () @trusted {
						// Fast cast can be trusted in this case, we already did the check.
						import util.fastcast;
						return fastCast!SymType(s);
					} ());
					return;
				}
			}
		}
		
		assert(0, "Can't process " ~ tid.toString());
	}
}

struct SymbolAnalyzer {
	private SemanticPass pass;
	alias pass this;
	
	alias Step = SemanticPass.Step;
	
	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	void analyze(AstModule astm, Module m) {
		auto oldManglePrefix = manglePrefix;
		scope(exit) manglePrefix = oldManglePrefix;
		
		manglePrefix = "";
		
		import std.conv;
		foreach(name; astm.packages) {
			auto s = name.toString(context);
			manglePrefix = s.length.to!string() ~ s ~ manglePrefix;
		}
		
		auto name = astm.name.toString(context);
		manglePrefix ~= name.length.to!string() ~ name;
		
		// All modules implicitely import object.
		import d.semantic.declaration, d.context.name;
		m.members = DeclarationVisitor(pass)
			.flatten(new ImportDeclaration(m.location, [[BuiltinName!"object"]]) ~ astm.declarations, m);
		
		scheduler.require(m.members);
		m.step = Step.Processed;
	}
	
	void analyze(FunctionDeclaration fd, Function f) {
		import std.algorithm, std.array;
		auto params = f.params = fd.params.map!((p) {
			import d.semantic.type;
			auto t = TypeVisitor(pass).visit(p.type);
			
			Expression value;
			if (p.value) {
				import d.semantic.expression;
				value = ExpressionVisitor(pass).visit(p.value);
			}
			
			return new Variable(p.location, t, p.name, value);
		}).array();
		
		// If this is a closure, we add the context parameter.
		if (f.hasContext) {
			assert(ctxSym, "ctxSym must be defined if function has a context pointer.");
			
			import d.context.name;
			auto contextParameter = new Variable(f.location, Type.getContextType(ctxSym).getParamType(true, false), BuiltinName!"__ctx");
			params = contextParameter ~ params;
		}
		
		// Prepare statement visitor for return type.
		auto oldReturnType = returnType;
		auto oldManglePrefix = manglePrefix;
		scope(exit) {
			manglePrefix = oldManglePrefix;
			returnType = oldReturnType;
		}
		
		import std.conv;
		auto name = f.name.toString(context);
		manglePrefix = manglePrefix ~ to!string(name.length) ~ name;
		
		auto fbody = fd.fbody;
		bool isAuto = false;
		
		import d.context.name;
		immutable isCtor = f.name == BuiltinName!"__ctor";
		
		void buildType() {
			f.type = FunctionType(
				f.linkage,
				pass.returnType,
				params.map!(p => p.paramType).array(),
				fd.isVariadic,
			);
			
			assert(!isCtor || f.linkage == Linkage.D, "Only D linkage is supported for ctors.");
			switch (f.linkage) with(Linkage) {
				case D :
					import d.semantic.mangler;
					auto mangle = TypeMangler(pass).visit(f.type);
					mangle = f.hasThis ? mangle : ("FM" ~ mangle[1 .. $]);
					f.mangle = pass.context
						.getName("_D" ~ pass.manglePrefix ~ mangle);
					break;
				
				case C :
					f.mangle = f.name;
					break;
				
				default:
					import std.conv;
					assert(0, "Linkage " ~ to!string(f.linkage) ~ " is not supported.");
			}
			
			f.step = Step.Signed;
		}
		
		if (isCtor) {
			assert(f.hasThis, "Constructor must have a this pointer");
			
			auto ctorThis = thisType;
			if (ctorThis.isRef) {
				ctorThis = ctorThis.getParamType(false, ctorThis.isFinal);
				returnType = ctorThis;
				
				if (fbody) {
					import d.ast.statement;
					fbody = new AstBlockStatement(fbody.location, [
						fbody,
						new AstReturnStatement(f.location, new ThisExpression(f.location)),
					]);
				}
			} else {
				returnType = Type.get(BuiltinType.Void).getParamType(false, false);
			}
			
			auto thisParameter = new Variable(f.location, ctorThis, BuiltinName!"this");
			params = thisParameter ~ params;
			
			buildType();
		} else {
			// If it has a this pointer, add it as parameter.
			if (f.hasThis) {
				assert(thisType.getType().kind != TypeKind.Builtin, "thisType must be defined if funtion has a this pointer.");
				
				auto thisParameter = new Variable(f.location, thisType, BuiltinName!"this");
				params = thisParameter ~ params;
			}
			
			isAuto = fd.returnType.getType().isAuto;
			
			import d.semantic.type;
			returnType = isAuto
				? Type.get(BuiltinType.None).getParamType(false, false)
				: TypeVisitor(pass).visit(fd.returnType);
			
			// Compute return type.
			if (isAuto) {
				// Functions are always populated as resolution is order dependant.
				f.step = Step.Populated;
			} else {
				buildType();
			}
		}
		
		if (fbody) {
			auto oldCtxSym = ctxSym;
			scope(exit) ctxSym = oldCtxSym;
			
			// Update scope.
			auto dscope = f.dscope = f.hasContext
				? new ClosureScope(f, currentScope)
				: new SymbolScope(f, currentScope);
			
			ctxSym = f;
			
			// Register parameters.
			foreach(p; params) {
				p.mangle = p.name;
				p.step = Step.Processed;
				
				if (!p.name.isEmpty()) {
					dscope.addSymbol(p);
				}
			}
			
			// And flatten.
			import d.semantic.statement;
			StatementVisitor(pass).getBody(f, fbody);
			
			import d.semantic.flow;
			f.closure = FlowAnalyzer(pass).getClosure(f);
		}
		
		if (isAuto) {
			// If nothing has been set, the function returns void.
			auto t = returnType.getType();
			if (t.kind == TypeKind.Builtin && t.builtin == BuiltinType.None) {
				returnType = Type.get(BuiltinType.Void).getParamType(returnType.isRef, returnType.isFinal);
			}
			
			buildType();
		}
		
		assert(f.fbody || !isAuto, "Auto functions must have a body");
		f.step = Step.Processed;
	}
	
	void analyze(FunctionDeclaration d, Method m) {
		analyze(d, cast(Function) m);
	}
	
	private auto getValue(VariableDeclaration d) {
		auto stc = d.storageClass;
		
		if (d.type.isAuto) {
			// XXX: remove selective import when dmd is sane.
			import d.semantic.expression : ExpressionVisitor;
			return ExpressionVisitor(pass).visit(d.value);
		}
		
		import d.semantic.type : TypeVisitor;
		auto type = TypeVisitor(pass).withStorageClass(stc).visit(d.type);
		if (auto vi = cast(AstVoidInitializer) d.value) {
			return new VoidInitializer(vi.location, type);
		}
		
		// XXX: remove selective import when dmd is sane.
		import d.semantic.expression : ExpressionVisitor;
		import d.semantic.defaultinitializer : InitBuilder;
		auto value = d.value
			? ExpressionVisitor(pass).visit(d.value)
			: InitBuilder(pass, d.location).visit(type);
		
		return buildImplicitCast(pass, d.location, type, value);
	}
	
	private void analyzeVarLike(V)(VariableDeclaration d, V v) {
		auto value = getValue(d);
		v.type = value.type;
		
		assert(value);
		static if (is(typeof(v.value) : CompileTimeExpression)) {
			value = v.value = evaluate(value);
		} else {
			value = v.value = v.storage.isGlobal
				? evaluate(value)
				: value;
		}
		
		// XXX: Make sure type is at least signed.
		import d.semantic.sizeof;
		SizeofVisitor(pass).visit(value.type);
		
		v.mangle = v.name;
		static if(is(V : Variable)) {
			if (v.storage == Storage.Static) {
				assert(v.linkage == Linkage.D, "I mangle only D !");
				
				auto name = v.name.toString(context);
				
				import d.semantic.mangler;
				auto mangle = TypeMangler(pass).visit(v.type);
				
				import std.conv;
				mangle = "_D" ~ manglePrefix ~ to!string(name.length) ~ name ~ mangle;
				
				v.mangle = context.getName(mangle);
			}
		}
		
		v.step = Step.Processed;
	}
	
	void analyze(VariableDeclaration d, Variable v) {
		analyzeVarLike(d, v);
	}
	
	void analyze(VariableDeclaration d, Field f) {
		analyzeVarLike(d, f);
	}
	
	void analyze(IdentifierAliasDeclaration d, SymbolAlias a) {
		import d.semantic.identifier : AliasResolver;
		a.symbol = AliasResolver!(function Symbol(identified) {
			alias T = typeof(identified);
			static if (is(T : Symbol)) {
				return identified;
			} else {
				assert(0, "Not implemented for " ~ typeid(identified).toString());
			}
		})(pass).visit(d.identifier);
		
		process(a);
	}
	
	void process(SymbolAlias a) {
		// Mangling
		scheduler.require(a.symbol, Step.Populated);
		a.mangle = a.symbol.mangle;
		
		scheduler.require(a.symbol, Step.Signed);
		a.hasContext = a.symbol.hasContext;
		a.step = Step.Processed;
	}
	
	void analyze(TypeAliasDeclaration d, TypeAlias a) {
		import d.semantic.type : TypeVisitor;
		a.type = TypeVisitor(pass).visit(d.type);
		
		import d.semantic.mangler;
		a.mangle = context.getName(TypeMangler(pass).visit(a.type));
		
		a.step = Step.Processed;
	}
	
	void analyze(ValueAliasDeclaration d, ValueAlias a) {
		// XXX: remove selective import when dmd is sane.
		import d.semantic.expression : ExpressionVisitor;
		a.value = evaluate(ExpressionVisitor(pass).visit(d.value));
		
		import d.semantic.mangler;
		auto typeMangle = TypeMangler(pass).visit(a.value.type);
		auto valueMangle = ValueMangler(pass).visit(a.value);
		a.mangle = context.getName(typeMangle ~ valueMangle);
		
		a.step = Step.Processed;
	}
	
	void analyze(StructDeclaration d, Struct s) {
		auto oldManglePrefix = manglePrefix;
		auto oldThisType = thisType;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			thisType = oldThisType;
		}
		
		auto type = Type.get(s);
		thisType = type.getParamType(true, false);
		
		// Update mangle prefix.
		import std.conv;
		auto name = s.name.toString(context);
		manglePrefix = manglePrefix ~ name.length.to!string() ~ name;
		
		assert(s.linkage == Linkage.D || s.linkage == Linkage.C);
		auto mangle = "S" ~ manglePrefix;
		s.mangle = context.getName(mangle);
		
		auto dscope = s.dscope = s.hasContext
			? new ClosureScope(s, currentScope)
			: new SymbolScope(s, currentScope);
		
		// XXX: d is hijacked without explicit import
		import d.context.name : BuiltinName;
		Field[] fields;
		if (s.hasContext) {
			auto ctxPtr = Type.getContextType(ctxSym).getPointer();
			auto ctx = new Field(
				s.location,
				0,
				ctxPtr,
				BuiltinName!"__ctx",
				new NullLiteral(s.location, ctxPtr),
			);
			
			ctx.step = Step.Processed;
			fields = [ctx];
		}
		
		auto members = DeclarationVisitor(pass).flatten(d.members, s);
		
		auto init = new Variable(d.location, type, BuiltinName!"init");
		init.storage = Storage.Static;
		init.mangle = context.getName("_D" ~ manglePrefix ~ to!string("init".length) ~ "init" ~ mangle);
		init.step = Step.Signed;
		
		dscope.addSymbol(init);
		s.step = Step.Populated;
		
		import std.algorithm, std.array;
		auto otherSymbols = members.filter!((m) {
			if (auto f = cast(Field) m) {
				fields ~= f;
				return false;
			}
			
			return true;
		}).array();
		
		scheduler.require(fields, Step.Signed);
		
		s.members ~= init;
		s.members ~= fields;
		
		scheduler.require(fields);
		
		init.value = new CompileTimeTupleExpression(d.location, type, fields.map!(f => cast(CompileTimeExpression) f.value).array());
		init.step = Step.Processed;
		
		s.step = Step.Signed;
		
		scheduler.require(otherSymbols);
		s.members ~= otherSymbols;
		
		s.step = Step.Processed;
	}
	
	void analyze(UnionDeclaration d, Union u) {
		auto oldManglePrefix = manglePrefix;
		auto oldThisType = thisType;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			thisType = oldThisType;
		}
		
		auto type = Type.get(u);
		thisType = type.getParamType(true, false);
		
		// Update mangle prefix.
		import std.conv;
		auto name = u.name.toString(context);
		manglePrefix = manglePrefix ~ name.length.to!string() ~ name;
		
		// XXX: For some reason dmd mangle the same way as structs ???
		assert(u.linkage == Linkage.D || u.linkage == Linkage.C);
		auto mangle = "S" ~ manglePrefix;
		u.mangle = context.getName(mangle);
		
		auto dscope = u.dscope = u.hasContext
			? new ClosureScope(u, currentScope)
			: new SymbolScope(u, currentScope);
		
		// XXX: d is hijacked without explicit import
		import d.context.name : BuiltinName;
		
		Field[] fields;
		if (u.hasContext) {
			auto ctxPtr = Type.getContextType(ctxSym).getPointer();
			auto ctx = new Field(
				u.location,
				0,
				ctxPtr,
				BuiltinName!"__ctx",
				new NullLiteral(u.location, ctxPtr),
			);
			
			ctx.step = Step.Processed;
			fields = [ctx];
		}
		
		auto members = DeclarationVisitor(pass).flatten(d.members, u);
		
		auto init = new Variable(u.location, type, BuiltinName!"init");
		init.storage = Storage.Static;
		init.mangle = context.getName("_D" ~ manglePrefix ~ to!string("init".length) ~ "init" ~ mangle);
		init.step = Step.Signed;
		
		dscope.addSymbol(init);
		u.step = Step.Populated;
		
		import std.algorithm, std.array;
		auto otherSymbols = members.filter!((m) {
			if (auto f = cast(Field) m) {
				fields ~= f;
				return false;
			}
			
			return true;
		}).array();
		
		scheduler.require(fields, Step.Signed);
		
		u.members ~= init;
		u.members ~= fields;
		
		u.step = Step.Signed;
		
		scheduler.require(fields);
		
		init.value = new VoidInitializer(u.location, type);
		init.step = Step.Processed;
		
		scheduler.require(otherSymbols);
		u.members ~= otherSymbols;
		
		u.step = Step.Processed;
	}
	
	void analyze(ClassDeclaration d, Class c) {
		auto oldManglePrefix = manglePrefix;
		auto oldThisType = thisType;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			thisType = oldThisType;
		}
		
		thisType = Type.get(c).getParamType(false, true);
		
		// Update mangle prefix.
		import std.conv;
		auto name = c.name.toString(context);
		manglePrefix = manglePrefix ~ name.length.to!string() ~ name;
		c.mangle = context.getName("C" ~ manglePrefix);
		
		auto dscope = c.dscope = c.hasContext
			? new ClosureScope(c, currentScope)
			: new SymbolScope(c, currentScope);
		
		Field[] baseFields;
		Method[] baseMethods;
		foreach(i; d.bases) {
			import d.semantic.identifier : AliasResolver;
			c.base = AliasResolver!(function Class(identified) {
				static if (is(typeof(identified) : Symbol)) {
					if (auto c = cast(Class) identified) {
						return c;
					}
				}
				
				static if (is(typeof(identified.location))) {
					import d.exception;
					throw new CompileException(identified.location, typeid(identified).toString() ~ " is not a class.");
				} else {
					// for typeof(null)
					assert(0);
				}
			})(pass).visit(i);
			
			break;
		}
		
		// If no inheritance is specified, inherit from object.
		if (!c.base) {
			c.base = pass.object.getObject();
		}
		
		uint fieldIndex = 0;
		uint methodIndex = 0;
		
		// object.Object, let's do some compiler magic.
		if (c is c.base) {
			auto vtblType = Type.get(BuiltinType.Void).getPointer(TypeQualifier.Immutable);
			
			// XXX: d is hijacked without explicit import
			import d.context.name : BuiltinName;

			// TODO: use defaultinit.
			auto vtbl = new Field(d.location, 0, vtblType, BuiltinName!"__vtbl", null);
			vtbl.step = Step.Processed;
			
			baseFields = [vtbl];
			
			fieldIndex = 1;
		} else {
			scheduler.require(c.base);
			
			fieldIndex = 0;
			foreach(m; c.base.members) {
				import std.algorithm;
				if (auto field = cast(Field) m) {
					baseFields ~= field;
					fieldIndex = max(fieldIndex, field.index);
					
					dscope.addSymbol(field);
				} else if (auto method = cast(Method) m) {
					baseMethods ~= method;
					methodIndex = max(methodIndex, method.index);
					
					dscope.addOverloadableSymbol(method);
				}
			}
			
			fieldIndex++;
		}
		
		if (c.hasContext) {
			// XXX: check for duplicate.
			auto ctxPtr = Type.getContextType(ctxSym).getPointer();

			import d.context.name;
			auto ctx = new Field(
				c.location,
				fieldIndex++,
				ctxPtr,
				BuiltinName!"__ctx",
				new NullLiteral(c.location, ctxPtr),
			);
			
			ctx.step = Step.Processed;
			baseFields ~= ctx;
		}
		
		auto members = DeclarationVisitor(pass)
			.flatten(d.members, c, fieldIndex, methodIndex);
		
		c.step = Step.Signed;
		
		uint overloadCount = 0;
		foreach(m; members) {
			if (auto method = cast(Method) m) {
				scheduler.require(method, Step.Signed);
				
				auto mt = method.type;
				auto rt = mt.returnType;
				auto ats = mt.parameters[1 .. $];
				
				CandidatesLoop: foreach(ref candidate; baseMethods) {
					if (!candidate || method.name != candidate.name) {
						continue;
					}
					
					auto ct = candidate.type;
					if (ct.isVariadic != mt.isVariadic) {
						continue;
					}
					
					auto crt = ct.returnType;
					auto cts = ct.parameters[1 .. $];
					if (ats.length != cts.length || rt.isRef != crt.isRef) {
						continue;
					}
					
					if (implicitCastFrom(pass, rt.getType(), crt.getType()) < CastKind.Exact) {
						continue;
					}
					
					import std.range;
					foreach(at, ct; lockstep(ats, cts)) {
						if (at.isRef != ct.isRef) {
							continue CandidatesLoop;
						}
						
						if (implicitCastFrom(pass, ct.getType(), at.getType()) < CastKind.Exact) {
							continue CandidatesLoop;
						}
					}
					
					if (method.index == 0) {
						method.index = candidate.index;
						
						// Remove candidate from scope.
						auto os = cast(OverloadSet) dscope
							.resolve(method.location, method.name);
						assert(os, "This must be an overload set");
						
						uint i = 0;
						while (os.set[i] !is candidate) {
							i++;
						}
						
						foreach(s; os.set[i + 1 .. $]) {
							os.set[i++] = s;
						}
						
						os.set = os.set[0 .. i];
						
						overloadCount++;
						candidate = null;
						break;
					} else {
						import d.exception;
						throw new CompileException(
							method.location,
							method.name.toString(context) ~ " overrides a base class methode but is not marked override",
						);
					}
				}
				
				if (method.index == 0) {
					import d.exception;
					throw new CompileException(method.location, "Override not found for " ~ method.name.toString(context));
				}
			}
		}
		
		// Remove overlaoded base method.
		if (overloadCount) {
			uint i = 0;
			while(baseMethods[i] !is null) {
				i++;
			}
			
			foreach(baseMethod; baseMethods[i + 1 .. $]) {
				if (baseMethod) {
					baseMethods[i++] = baseMethod;
				}
			}
			
			baseMethods = baseMethods[0 .. i];
		}
		
		c.members = cast(Symbol[]) baseFields;
		c.members ~= baseMethods;
		scheduler.require(members);
		c.members ~= members;
		
		c.step = Step.Processed;
	}

	void analyze(InterfaceDeclaration d, Interface i) {
		auto oldManglePrefix = manglePrefix;
		auto oldThisType = thisType;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			thisType = oldThisType;
		}
		
		thisType = Type.get(i).getParamType(false, true);
		
		import std.conv;
		auto name = i.name.toString(context);
		manglePrefix = manglePrefix ~ name.length.to!string();
		
		i.mangle = context.getName("I" ~ manglePrefix);
		
		assert(d.members.length == 0, "Member support not implemented for interfaces yet");
		assert(d.bases.length == 0, "Interface inheritance not implemented yet");
		
		// TODO: lots of stuff to add
		
		i.step = Step.Processed;
	}

	void analyze(EnumDeclaration d, Enum e) in {
		assert(e.name.isDefined, "anonymous enums must be flattened !");
	} body {
		auto oldManglePrefix = manglePrefix;
		auto oldScope = currentScope;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			currentScope = oldScope;
		}
		
		currentScope = e.dscope = new SymbolScope(e, oldScope);
		
		import d.semantic.type : TypeVisitor;
		e.type = d.type.isAuto
			? Type.get(BuiltinType.Int)
			: TypeVisitor(pass).visit(d.type);
		
		auto type = Type.get(e);
		
		if (e.type.kind != TypeKind.Builtin) {
			import d.exception;
			throw new CompileException(e.location, "Unsupported enum type " ~ e.type.toString(context));
		}
		
		auto bt = e.type.builtin;
		if (!isIntegral(bt) && bt != BuiltinType.Bool) {
			import d.exception;
			throw new CompileException(e.location, "Unsupported enum type " ~ e.type.toString(context));
		}
		
		import std.conv;
		auto name = e.name.toString(context);
		manglePrefix = manglePrefix ~ to!string(name.length) ~ name;
		
		assert(e.linkage == Linkage.D || e.linkage == Linkage.C);
		e.mangle = context.getName("E" ~ manglePrefix);
		
		Variable previous;
		Expression one;
		foreach(vd; d.entries) {
			auto location = vd.location;
			auto v = new Variable(vd.location, type, vd.name);
			v.storage = Storage.Enum;
			
			e.dscope.addSymbol(v);
			e.entries ~= v;
			
			auto dv = vd.value;
			if (dv is null) {
				if (previous) {
					if (!one) {
						one = new IntegerLiteral(location, 1, bt);
					}
					
					// XXX: consider using AstExpression and always
					// follow th same path.
					scheduler.require(previous, Step.Signed);
					v.value = new BinaryExpression(
						location,
						type,
						BinaryOp.Add,
						new VariableExpression(location, previous),
						one,
					);
				} else {
					v.value = new IntegerLiteral(location, 0, bt);
				}
			}
			
			pass.scheduler.schedule(dv, v);
			previous = v;
		}
		
		e.step = Step.Signed;
		
		scheduler.require(e.entries);
		e.step = Step.Processed;
	}
	
	void analyze(AstExpression dv, Variable v) in {
		assert(v.storage == Storage.Enum);
		assert(v.type.kind == TypeKind.Enum);
	} body {
		auto e = v.type.denum;
		
		if (dv !is null) {
			assert(v.value is null);
			
			import d.semantic.expression;
			v.value = ExpressionVisitor(pass).visit(dv);
		}
		
		assert(v.value);
		v.step = Step.Signed;
		
		v.value = evaluate(v.value);
		v.step = Step.Processed;
	}
	
	void analyze(TemplateDeclaration d, Template t) {
		// XXX: compute a proper mangling for templates.
		import std.conv;
		auto name = t.name.toString(context);
		t.mangle = context.getName(manglePrefix ~ name.length.to!string() ~ name);
		
		auto oldScope = currentScope;
		scope(exit) currentScope = oldScope;
		
		auto dscope = currentScope = t.dscope = new SymbolScope(t, oldScope);
		
		t.parameters.length = d.parameters.length;
		
		// Register parameter in the scope.
		auto none = Type.get(BuiltinType.None);
		foreach_reverse(i, p; d.parameters) {
			if (auto atp = cast(AstTypeTemplateParameter) p) {
				auto tp = new TypeTemplateParameter(atp.location, atp.name, cast(uint) i, none, none);
				dscope.addSymbol(tp);
				
				import d.semantic.type : TypeVisitor;
				tp.specialization = TypeVisitor(pass).visit(atp.specialization);
				tp.defaultValue = TypeVisitor(pass).visit(atp.defaultValue);
				
				tp.step = Step.Signed;
				t.parameters[i] = tp;
			} else if (auto avp = cast(AstValueTemplateParameter) p) {
				auto vp = new ValueTemplateParameter(avp.location, avp.name, cast(uint) i, none, null);
				dscope.addSymbol(vp);
				
				import d.semantic.type : TypeVisitor;
				vp.type = TypeVisitor(pass).visit(avp.type);
				
				if (avp.defaultValue !is null) {
					import d.semantic.expression : ExpressionVisitor;
					vp.defaultValue = ExpressionVisitor(pass).visit(avp.defaultValue);
				}
				
				vp.step = Step.Signed;
				t.parameters[i] = vp;
			} else if (auto aap = cast(AstAliasTemplateParameter) p) {
				auto ap = new AliasTemplateParameter(aap.location, aap.name, cast(uint) i);
				dscope.addSymbol(ap);
				
				ap.step = Step.Signed;
				t.parameters[i] = ap;
			} else if (auto atap = cast(AstTypedAliasTemplateParameter) p) {
				auto tap = new TypedAliasTemplateParameter(atap.location, atap.name, cast(uint) i, none);
				dscope.addSymbol(tap);
				
				import d.semantic.type : TypeVisitor;
				tap.type = TypeVisitor(pass).visit(atap.type);
				
				tap.step = Step.Signed;
				t.parameters[i] = tap;
			} else {
				assert(0, typeid(p).toString() ~ " template parameters are not supported.");
			}
		}
		
		t.step = Step.Populated;
		
		// TODO: support multiple IFTI.
		foreach(m; t.members) {
			if (auto fun = cast(FunctionDeclaration) m) {
				if (fun.name != t.name) {
					continue;
				}
				
				import d.semantic.type, std.algorithm, std.array;
				t.ifti = fun.params
					.map!(p => TypeVisitor(pass).visit(p.type).getType())
					.array();
				
				break;
			}
		}
		
		t.step = Step.Processed;
	}
	
	void analyze(Template t, TemplateInstance i) {
		auto oldManglePrefix = manglePrefix;
		auto oldCtxSym = ctxSym;
		
		scope(exit) {
			manglePrefix = oldManglePrefix;
			ctxSym = oldCtxSym;
		}
		
		manglePrefix = i.mangle.toString(context);
		auto dscope = i.dscope = new SymbolScope(i, t.dscope);
		
		// Prefilled members are template arguments.
		foreach(m; i.members) {
			if (m.hasContext) {
				assert(t.storage >= Storage.Static, "template can only have one context");
				
				import d.semantic.closure;
				ctxSym = ContextFinder(pass).visit(m);
				
				i.storage = Storage.Local;
			}
			
			dscope.addSymbol(m);
		}
		
		import d.semantic.declaration;
		auto members = DeclarationVisitor(pass).flatten(t.members, i);
		scheduler.require(members);
		
		i.members ~= members;
		i.step = Step.Processed;
	}
}
