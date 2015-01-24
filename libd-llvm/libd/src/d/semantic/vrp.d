module d.semantic.vrp;

import d.ir.expression;
import d.ir.symbol;
import d.ir.type;

import d.semantic.semantic;

struct ValueRange {
	ulong min = ulong.min;
	ulong max = ulong.max;
	
	this(ulong min, ulong max) {
		this.min = min;
		this.max = max;
	}
	
	this(ulong value) {
		this(value, value);
	}
	
	@property
	bool full() const {
		return (min - max) == 1;
	}
	
	auto complement(Type t) const {
		return ValueRange(1 + ~max, 1 + ~min).repack(t);
	}
	
	auto repack(Type t) const {
		auto mask = getMask(t);
		
		// If overflow is identical, then simply strip it.
		return ((min & ~mask) == (max & ~mask))
			? ValueRange(min & mask, max & mask)
			: ValueRange(0, mask);
	}
	
	bool opEquals(ValueRange rhs) const {
		return (full && rhs.full) || (min == rhs.min && max == rhs.max);
	}
	
static:
	ValueRange get(ulong u0, ulong u1, ulong u2, ulong u3) {
		import std.algorithm;
		return ValueRange(min(u0, u1, u2, u3), max(u0, u1, u2, u3));
	}
	
	ValueRange get(Type t) {
		return ValueRange(0, getMask(t));
	}
	
	ulong getMask(Type t) {
		if (t.kind == TypeKind.Enum) {
			return getMask(t.denum.type);
		}
		
		if (t.hasPointerABI()) {
			return ulong.max;
		}
		
		auto bt = t.builtin;
		assert(canConvertToIntegral(bt));
		
		if (bt == BuiltinType.Bool) {
			return 1;
		}
		
		bt = isChar(bt)
			? integralOfChar(bt)
			: unsigned(bt);
		
		return getMax(bt);
	}
}

// Conflict with Interface in object.di
alias Interface = d.ir.symbol.Interface;

struct ValueRangePropagator {
	private SemanticPass pass;
	alias pass this;
	
	this(SemanticPass pass) {
		this.pass = pass;
	}
	
	bool canFit(Expression e, Type t) {
		auto ev = visit(e);
		auto tv = ValueRange.get(t);
		
		return ev.min >= tv.min && ev.max <= tv.max;
	}
	
	// Expressions
	ValueRange visit(Expression e) in {
		assert(e.type.kind == TypeKind.Builtin && isIntegral(e.type.builtin), "VRP expect integral types.");
	} body {
		return this.dispatch(e);
	}
	
	ValueRange visit(BooleanLiteral e) {
		return ValueRange(e.value);
	}
	
	ValueRange visit(IntegerLiteral!false e) {
		return ValueRange(e.value).repack(e.type);
	}
	
	ValueRange visit(IntegerLiteral!true e) {
		return ValueRange(e.value).repack(e.type);
	}
	
	private auto add(ValueRange lhs, ValueRange rhs, Type t) {
		auto lrange = lhs.max - lhs.min;
		auto rrange = rhs.max - rhs.min;
		
		// If the total range overflow, pessimise.
		auto range = lrange + rrange;
		return (range < lrange && range < rrange)
			? ValueRange.get(t)
			: ValueRange(lhs.min + rhs.min, lhs.max + rhs.max).repack(t);
	}
	
	private auto sub(ValueRange lhs, ValueRange rhs, Type t) {
		return add(lhs, rhs.complement(t), t);
	}
	
	ValueRange visit(BinaryExpression e) {
		switch (e.op) with(BinaryOp) {
			case Comma :
			case Assign :
				return visit(e.rhs).repack(e.type);
			
			case Add :
				return add(visit(e.lhs), visit(e.rhs), e.type);
			
			case Sub :
				// Get the complement and compute as an add.
				return sub(visit(e.lhs), visit(e.rhs), e.type);
			
			case Concat :
				assert(0);
			
			case Mul, Div, Mod :
			
			default :
				assert(0, "Not implemented.");
		}
	}
	
	ValueRange visit(UnaryExpression e) {
		assert(0, "Not implemented.");
	}
	
	ValueRange visit(VariableExpression e) {
		auto v = e.var;
		scheduler.require(v, Step.Processed);
		
		return (v.storage == Storage.Enum || v.type.qualifier == TypeQualifier.Immutable)
			? visit(v.value)
			: ValueRange.get(v.type);
	}
}

unittest {
	auto v = ValueRange.get(Type.get(BuiltinType.Bool));
	assert(v.min == bool.min);
	assert(v.max == bool.max);
	
	v = ValueRange.get(Type.get(BuiltinType.Byte));
	assert(v.min == ubyte.min);
	assert(v.max == ubyte.max);
	
	v = ValueRange.get(Type.get(BuiltinType.Char));
	assert(v.min == ubyte.min);
	assert(v.max == ubyte.max);
	
	v = ValueRange.get(Type.get(BuiltinType.Ulong));
	assert(v.min == ulong.min);
	assert(v.max == ulong.max);
	
	v = ValueRange.get(Type.get(BuiltinType.Void).getPointer());
	assert(v.min == ulong.min);
	assert(v.max == ulong.max);
	
	v = ValueRange.get(Type.get(Class.init));
	assert(v.min == ulong.min);
	assert(v.max == ulong.max);
}

unittest {
	auto vrp = ValueRangePropagator();
	
	import d.location;
	auto v = vrp.visit(new BooleanLiteral(Location.init, false));
	assert(v.min == false);
	assert(v.max == false);
	
	v = vrp.visit(new BooleanLiteral(Location.init, true));
	assert(v.min == true);
	assert(v.max == true);
	
	v = vrp.visit(new IntegerLiteral!true(Location.init, -9, BuiltinType.Byte));
	assert(v.min == cast(ubyte) -9);
	assert(v.max == cast(ubyte) -9);
	
	v = vrp.visit(new IntegerLiteral!false(Location.init, 42, BuiltinType.Uint));
	assert(v.min == 42);
	assert(v.max == 42);
}

unittest {
	auto vrp = ValueRangePropagator();
	
	import d.location;
	auto i1 = new IntegerLiteral!true(Location.init, -9, BuiltinType.Int);
	auto i2 = new IntegerLiteral!true(Location.init, 42, BuiltinType.Int);
	
	auto v = vrp.visit(new BinaryExpression(Location.init, Type.get(BuiltinType.Int), BinaryOp.Comma, i1, i2));
	assert(v == ValueRange(42));
	
	v = vrp.visit(new BinaryExpression(Location.init, Type.get(BuiltinType.Int), BinaryOp.Add, i1, i2));
	assert(v == ValueRange(33));
	
	v = vrp.visit(new BinaryExpression(Location.init, Type.get(BuiltinType.Int), BinaryOp.Sub, i1, i2));
	assert(v == ValueRange(cast(uint) -51));
}

unittest {
	auto vrp = ValueRangePropagator();
	auto t = Type.get(BuiltinType.Long);
	
	void testAdd(ValueRange lhs, ValueRange rhs, ValueRange res) {
		auto v = vrp.add(lhs, rhs, t);
		assert(v == res, "a + b");
		
		v = vrp.add(rhs, lhs, t);
		assert(v == res, "a + b = b + a");
		
		v = vrp.add(lhs.complement(t), rhs.complement(t), t);
		assert(v == res.complement(t), "-a + -b = -(a + b)");
	}
	
	testAdd(ValueRange(1), ValueRange(-1), ValueRange(0));
	testAdd(ValueRange(-5, 0), ValueRange(-1, 5), ValueRange(-6, 5));
	testAdd(ValueRange(5, 6), ValueRange(-3, 5), ValueRange(2, 11));
	testAdd(ValueRange(-12, 85), ValueRange(5, 53), ValueRange(-7, 138));
	testAdd(ValueRange(0, -42), ValueRange(42, -1), ValueRange(0, -1));
	
	void testSub(ValueRange lhs, ValueRange rhs, ValueRange res) {
		auto v = vrp.sub(lhs, rhs, t);
		assert(v == res, "a - b");
		
		v = vrp.sub(rhs, lhs, t);
		assert(v == res.complement(t), "b - a = -(a - b)");
		
		v = vrp.add(lhs, rhs.complement(t), t);
		assert(v == res, "a + -b = a - b");
		
		v = vrp.sub(lhs.complement(t), rhs.complement(t), t);
		assert(v == res.complement(t), "-a - -b = -(a - b)");
	}
	
	testSub(ValueRange(-1), ValueRange(1), ValueRange(-2));
}

