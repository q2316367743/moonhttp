///|
/// Entry point for the CLI or runnable program in this template.
/// Keep main focused; move logic into the library package.
/// Run with `moon run cmd/main` from the project root.

struct Math {
  a: Int
  b: Int
}

fn Math::sum(self: Math) -> Int {
  return self.a + self.b
}

fn main {
  let math = Math::{ a: 5, b: 10 };
  println(math.sum());
  println(Math::sum(math));
}
