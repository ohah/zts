import { describe, test, expect, afterEach } from "bun:test";
import { bundleAndRun } from "./helpers";

// 런타임 헬퍼 (번들러가 아직 자동 주입하지 않으므로 인라인)
const HELPERS = `
var __extends = function(d, b) {
  for (var p in b) if (Object.prototype.hasOwnProperty.call(b, p)) d[p] = b[p];
  function __() { this.constructor = d; }
  d.prototype = b === null ? Object.create(b) : (__.prototype = b.prototype, new __());
};
var __generator = function(body) {
  var _ = { label: 0, sent: function() { return t[1]; }, trys: [], ops: [] }, f, y, t, g;
  return g = { next: verb(0), "throw": verb(1), "return": verb(2) }, g[Symbol.iterator] = function() { return this; }, g;
  function verb(n) { return function(v) { return step([n, v]); }; }
  function step(op) {
    if (f) throw new TypeError("Generator is already executing.");
    while (g && (g = 0, op[0] && (_ = 0)), _) try {
      if (f = 1, y && (t = op[0] & 2 ? y["return"] : op[0] ? y["throw"] || ((t = y["return"]) && t.call(y), 0) : y.next) && !(t = t.call(y, op[1])).done) return t;
      if (y = 0, t) op = [op[0] & 2, t.value];
      switch (op[0]) {
        case 0: case 1: t = op; break;
        case 4: _.label++; return { value: op[1], done: false };
        case 5: _.label++; y = op[1]; op = [0]; continue;
        case 7: op = _.ops.pop(); _.trys.pop(); continue;
        default:
          if (!(t = _.trys, t = t.length > 0 && t[t.length - 1]) && (op[0] === 6 || op[0] === 2)) { _ = 0; continue; }
          if (op[0] === 3 && (!t || (op[1] > t[0] && op[1] < t[3]))) { _.label = op[1]; break; }
          if (op[0] === 6 && _.label < t[1]) { _.label = t[1]; t = op; break; }
          if (t && _.label < t[2]) { _.label = t[2]; _.ops.push(op); break; }
          if (t[2]) _.ops.pop();
          _.trys.pop(); continue;
      }
      op = body.call(null, _);
    } catch (e) { op = [6, e]; y = 0; } finally { f = t = 0; }
    if (op[0] & 5) throw op[1]; return { value: op[0] ? op[1] : void 0, done: true };
  }
};
var __async = function(fn) {
  return function() {
    var args = arguments, self = this;
    return new Promise(function(resolve, reject) {
      var gen = fn.apply(self, args);
      function step(key, arg) {
        try { var info = gen[key](arg); var value = info.value; }
        catch (error) { reject(error); return; }
        if (info.done) resolve(value);
        else Promise.resolve(value).then(function(v) { step("next", v); }, function(e) { step("throw", e); });
      }
      step("next");
    });
  };
};
var __rest = function(s, e) {
  var t = {};
  for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p) && e.indexOf(p) < 0) t[p] = s[p];
  return t;
};
`;

function withHelpers(code: string): string {
  return HELPERS + code;
}

describe("ES 다운레벨링 런타임 테스트", () => {
  let cleanup: (() => Promise<void>) | undefined;

  afterEach(async () => {
    if (cleanup) {
      await cleanup();
      cleanup = undefined;
    }
  });

  // ===== ES2015 =====

  describe("ES2015", () => {
    test("template literal → string concat", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const name = 'world'; console.log(`hello ${name}`);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello world");
    });

    test("arrow function", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const add = (a: number, b: number) => a + b; console.log(add(1, 2));" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("arrow this capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Obj { x = 10; getX() { const fn = () => this.x; return fn(); } }
            console.log(new Obj().getX());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("let/const → var", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let x = 1; const y = 2; console.log(x + y);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("default params", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "function greet(name = 'world') { return 'hello ' + name; } console.log(greet());",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello world");
    });

    test("rest params", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "function sum(...nums: number[]) { return nums.reduce((a, b) => a + b, 0); } console.log(sum(1, 2, 3));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("spread array", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const a = [1, 2]; const b = [0, ...a, 3]; console.log(JSON.stringify(b));" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("[0,1,2,3]");
    });

    test("shorthand property", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const a = 1, b = 2; console.log(JSON.stringify({a, b}));" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"a":1,"b":2}');
    });

    test("destructuring object", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const { a, b } = { a: 1, b: 2, c: 3 }; console.log(a + b);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3");
    });

    test("destructuring array", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const [x, y] = [10, 20]; console.log(x + y);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("30");
    });

    test("destructuring rest (object)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(
            "const { a, ...rest } = { a: 1, b: 2, c: 3 }; console.log(a, JSON.stringify(rest));",
          ),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('1 {"b":2,"c":3}');
    });

    test("destructuring rest (array)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const [first, ...rest] = [1, 2, 3, 4]; console.log(first, JSON.stringify(rest));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 [2,3,4]");
    });

    test("class basic", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { x: number; constructor(x: number) { this.x = x; } double() { return this.x * 2; } }
            console.log(new Foo(5).double());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("class extends/super", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(`
            class Animal { name: string; constructor(name: string) { this.name = name; } speak() { return this.name; } }
            class Dog extends Animal { speak() { return super.speak() + " barks"; } }
            console.log(new Dog("Rex").speak());
          `),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Rex barks");
    });

    test("class getter/setter", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Box { _v = 0; get value() { return this._v; } set value(v: number) { this._v = v; } }
            const b = new Box(); b.value = 42; console.log(b.value);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("class expression", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const MyClass = class { x: number; constructor(x: number) { this.x = x; } get() { return this.x; } };
            console.log(new MyClass(7).get());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("7");
    });

    test("generator .next()", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(`
            function* gen() { yield 1; yield 2; yield 3; }
            const g = gen();
            const arr: number[] = [];
            let r = g.next(); while (!r.done) { arr.push(r.value); r = g.next(); }
            console.log(JSON.stringify(arr));
          `),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("[1,2,3]");
    });

    test("generator return", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(`
            function* gen() { yield 1; return 99; }
            const g = gen();
            console.log(JSON.stringify(g.next()), JSON.stringify(g.next()));
          `),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"value":1,"done":false} {"value":99,"done":true}');
    });

    test("private field (#field → WeakMap)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { #x = 10; getX() { return this.#x; } setX(v: number) { this.#x = v; } }
            const f = new Foo(); f.setX(42); console.log(f.getX());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("spread in function call", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "function add(a: number, b: number, c: number) { return a + b + c; } const args: [number, number, number] = [1, 2, 3]; console.log(add(...args));",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("6");
    });

    test("computed property", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const k = 'x'; const o = {[k]: 42}; console.log(o.x);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("for-of array", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const arr = [10, 20, 30]; let sum = 0; for (const x of arr) { sum += x; } console.log(sum);",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("60");
    });

    test("arrow arguments capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function outer() { const fn = () => arguments[0]; return fn(); }
            console.log(outer(42));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("class static method", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class MathUtil { static add(a: number, b: number) { return a + b; } }
            console.log(MathUtil.add(3, 4));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("7");
    });

    test("class field + constructor coexist", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { x = 10; y: number; constructor(y: number) { this.y = y; } sum() { return this.x + this.y; } }
            console.log(new Foo(20).sum());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("30");
    });

    test("generator yield value receive", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(`
            function* gen() { const x = yield 1; return x; }
            const g = gen(); g.next(); const r = g.next(42);
            console.log(JSON.stringify(r));
          `),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"value":42,"done":true}');
    });

    test("nested destructuring", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": "const { a, b: { c } } = { a: 1, b: { c: 2 } }; console.log(a, c);",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2");
    });

    test("destructuring default value", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const { a = 10, b = 20 } = { a: 1 }; console.log(a, b);" },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 20");
    });

    test("multiple class with private fields", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class A { #v = 1; get() { return this.#v; } }
            class B { #v = 2; get() { return this.#v; } }
            console.log(new A().get(), new B().get());
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2");
    });

    test("nested arrow this capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function Outer(this: any) {
              this.val = 10;
              var inner = () => {
                var deep = () => this.val;
                return deep();
              };
              console.log(inner());
            }
            new (Outer as any)();
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("arrow arguments capture", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function outer() {
              var f = () => Array.from(arguments).join(',');
              return f();
            }
            console.log(outer(1,2,3));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,3");
    });

    test("destructuring function parameter", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function greet({name, age}: {name:string, age:number}) {
              return name + ':' + age;
            }
            console.log(greet({name:'Alice', age:30}));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("Alice:30");
    });

    test("nested destructuring", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const obj = { a: { b: { c: 42 } } };
            var { a: { b: { c } } } = obj;
            console.log(c);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("array destructuring with skip", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const arr = [1, 2, 3, 4];
            var [a, , b] = arr;
            console.log(a, b);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 3");
    });

    test("for-of with destructuring", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const pairs: [string,number][] = [['a',1],['b',2]];
            var out: string[] = [];
            for (const [k,v] of pairs) { out.push(k + v); }
            console.log(out.join(','));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a1,b2");
    });

    test("class with toString override", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Point {
              x: number; y: number;
              constructor(x: number, y: number) { this.x = x; this.y = y; }
              toString() { return this.x + ',' + this.y; }
            }
            console.log('' + new Point(3, 4));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("3,4");
    });

    test("class extends with method override", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(`
            class Animal {
              speak() { return 'animal'; }
            }
            class Dog extends Animal {
              speak() { return 'woof'; }
            }
            class Cat extends Animal {}
            console.log(new Dog().speak(), new Cat().speak());
          `),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("woof animal");
    });

    test("generator with multiple yields", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(`
            function* multi() {
              yield 'a';
              yield 'b';
              yield 'c';
            }
            var out = [];
            var it = multi();
            var r = it.next();
            while (!r.done) { out.push(r.value); r = it.next(); }
            console.log(out.join(','));
          `),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a,b,c");
    });

    test("generator yield delegation", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": withHelpers(`
            function* inner() { yield 1; yield 2; }
            function* outer() { yield 0; yield* inner(); yield 3; }
            var out = [];
            var it = outer();
            var r = it.next();
            while (!r.done) { out.push(r.value); r = it.next(); }
            console.log(out.join(','));
          `),
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0,1,2,3");
    });

    test("template literal with multiple substitutions", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const name = 'world'; const n = 42; console.log(`hello ${name}, num=${n}`);",
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("hello world, num=42");
    });

    test("spread in object literal (es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = { x: 1 };
            const b = { ...a, y: 2, ...{ z: 3 } };
            console.log(JSON.stringify(b));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"x":1,"y":2,"z":3}');
    });

    test("default + rest params combined", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            function f(sep: string = ',', ...nums: number[]) {
              return nums.join(sep);
            }
            console.log(f(undefined, 1, 2, 3));
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1,2,3");
    });

    test("class static field expression", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class C { static a = 1; static b = C.a + 1; static c = C.b * 2; }
            console.log(C.a, C.b, C.c);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2 4");
    });

    test("computed property name", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const key = 'hello';
            const obj = { [key]: 'world', [1+1]: 'two' };
            console.log(obj.hello, obj[2]);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("world two");
    });
  });

  // ===== ES2016 (target=es2015) =====

  describe("ES2016 → es2015", () => {
    test("exponentiation **", async () => {
      const result = await bundleAndRun({ "index.ts": "console.log(2 ** 10);" }, "index.ts", [
        "--target=es2015",
      ]);
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1024");
    });

    test("exponentiation assignment **=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let x = 3; x **= 2; console.log(x);" },
        "index.ts",
        ["--target=es2015"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("9");
    });
  });

  // ===== ES2017 (target=es2016) =====
  // TODO: async/await → generator 변환 후 번들러의 __async 헬퍼 주입 문제 해결 필요
  // describe("ES2017 → es2016", () => { ... });

  // ===== ES2018 (target=es2017) =====

  describe("ES2018 → es2017", () => {
    test("object spread", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const a = { x: 1, y: 2 }; const b = { ...a, z: 3 }; console.log(JSON.stringify(b));",
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe('{"x":1,"y":2,"z":3}');
    });

    test("object spread override", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": "const a = { x: 1 }; const b = { ...a, x: 2 }; console.log(b.x);",
        },
        "index.ts",
        ["--target=es2017"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("2");
    });
  });

  // ===== ES2019 (target=es2018) =====

  describe("ES2019 → es2018", () => {
    test("optional catch binding", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "let caught = false; try { throw new Error(); } catch { caught = true; } console.log(caught);",
        },
        "index.ts",
        ["--target=es2018"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("true");
    });
  });

  // ===== ES2020 (target=es2019) =====

  describe("ES2020 → es2019", () => {
    test("nullish coalescing ??", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const a = null ?? 'default'; const b = 0 ?? 'default'; console.log(a, b);" },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("default 0");
    });

    test("optional chaining ?.", async () => {
      const result = await bundleAndRun(
        { "index.ts": "const obj: any = { a: { b: 42 } }; console.log(obj?.a?.b, obj?.x?.y);" },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42 undefined");
    });

    test("multiple ?? chaining", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const a = null; const b = undefined; const c = 0; console.log(a ?? b ?? c ?? 99);",
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0");
    });

    test("?? with false-y values preserved", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a = 0 ?? 'fallback';
            const b = '' ?? 'fallback';
            const c = false ?? 'fallback';
            const d = null ?? 'fallback';
            const e = undefined ?? 'fallback';
            console.log(a, b, c, d, e);
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("0  false fallback fallback");
    });

    test("?. with nullish base", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            const a: any = null;
            const b: any = undefined;
            const c: any = { x: { y: 42 } };
            console.log(a?.x?.y, b?.x?.y, c?.x?.y);
          `,
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("undefined undefined 42");
    });

    test("optional chaining call ?.()", async () => {
      const result = await bundleAndRun(
        {
          "index.ts":
            "const obj: any = { fn: () => 'ok' }; console.log(obj.fn?.(), obj.missing?.());",
        },
        "index.ts",
        ["--target=es2019"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("ok undefined");
    });
  });

  // ===== ES2021 (target=es2020) =====

  describe("ES2021 → es2020", () => {
    test("logical assignment ??=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let a: number | null = null; a ??= 10; console.log(a);" },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10");
    });

    test("logical assignment ||=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let a = 0; a ||= 5; console.log(a);" },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("5");
    });

    test("logical assignment &&=", async () => {
      const result = await bundleAndRun(
        { "index.ts": "let a = 1; a &&= 10; let b = 0; b &&= 10; console.log(a, b);" },
        "index.ts",
        ["--target=es2020"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("10 0");
    });
  });

  // ===== ES2022 (target=es2021) =====

  describe("ES2022 → es2021", () => {
    test("class static block", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { static value: number; static { Foo.value = 42; } }
            console.log(Foo.value);
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });

    test("class fields (target=es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { x = 1; static y = 2; }
            const f = new Foo(); console.log(f.x, Foo.y);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("1 2");
    });

    test("class static block with computed value", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Registry {
              static entries: string[] = [];
              static { Registry.entries.push('a', 'b'); }
              static { Registry.entries.push('c'); }
            }
            console.log(Registry.entries.join(','));
          `,
        },
        "index.ts",
        ["--target=es2021"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("a,b,c");
    });

    test("class static block (target=es5)", async () => {
      const result = await bundleAndRun(
        {
          "index.ts": `
            class Foo { static value: number; static { Foo.value = 42; } }
            console.log(Foo.value);
          `,
        },
        "index.ts",
        ["--target=es5"],
      );
      cleanup = result.cleanup;
      expect(result.exitCode).toBe(0);
      expect(result.runOutput).toBe("42");
    });
  });
});
