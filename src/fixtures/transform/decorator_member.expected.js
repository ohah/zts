class Foo {
	@log
	method() {}
	@readonly
	field = 1;
	@bound
	get value() {
		return this.field;
	}
	@trace
	accessor data = 2;
}
