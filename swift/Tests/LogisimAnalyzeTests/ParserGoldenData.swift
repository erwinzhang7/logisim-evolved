// ParserGoldenData: part of logisim-evolved.
//
// Derived from logisim-evolution, GPL-3.0-only. See LICENSE.md.
//
// Captured from the shipped 4.1.0 jar through tools/analyze/ParseProbe.java, against a model
// whose inputs are `a`, `b`, `c` and the 4-bit bus `x`, and whose outputs are `q` and `r`.
//
// Line format:
//
//     [A:]<input> || null
//     [A:]<input> || <math> ¦ <logic> ¦ <altLogic> ¦ <progBools> ¦ <progBits> ¦ <latex> ¦
//                    cnf=<bool> ¦ circ=<bool> ¦ xor=<bool> and=<bool> not=<bool>
//     [A:]<input> || ERR off=<n> len=<n> <english message>
//     [A:]<input> || EXC <java exception>       (upstream crashes; see ParserTests)
//
// An `A:` prefix means `parseMaybeAssignment` rather than `parse`. Some inputs carry a
// deliberate trailing space: without it, 4.1.0 throws StringIndexOutOfBoundsException on any
// expression ending in a bracketed bit subscript (see Parser.swift and ParserTests.swift).

enum ParserGolden {
  static let cases = #"""
a || a ¦ a ¦ a ¦ a ¦ a ¦ $a$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a+b || a+b ¦ a∨b ¦ a∨b ¦ a||b ¦ a|b ¦ $a+b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a*b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a b c || a⋅b⋅c ¦ a∧b∧c ¦ a∧b∧c ¦ a&&b&&c ¦ a&b&c ¦ $a \cdot b \cdot c$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
~a || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a' || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
!a || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a^b || a⊕b ¦ a⊻b ¦ a≢b ¦ a!=b ¦ a^b ¦ $a \oplus b$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a=b || a⊙b ¦ a≡b ¦ a≡b ¦ a==b ¦ a^~b ¦ $ \overline{a \oplus b}$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
a==b || a⊙b ¦ a≡b ¦ a≡b ¦ a==b ¦ a^~b ¦ $ \overline{a \oplus b}$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
a!=b || a⊕b ¦ a⊻b ¦ a≢b ¦ a!=b ¦ a^b ¦ $a \oplus b$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a&b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a&&b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a|b || a+b ¦ a∨b ¦ a∨b ¦ a||b ¦ a|b ¦ $a+b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a||b || a+b ¦ a∨b ¦ a∨b ¦ a||b ¦ a|b ¦ $a+b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a NOT b || a⋅~b ¦ a∧¬b ¦ a∧~b ¦ a&&!b ¦ a&~b ¦ $a \cdot  \overline{b} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a and b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a or b || a+b ¦ a∨b ¦ a∨b ¦ a||b ¦ a|b ¦ $a+b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a xor b || a⊕b ¦ a⊻b ¦ a≢b ¦ a!=b ¦ a^b ¦ $a \oplus b$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a equals b || a⊙b ¦ a≡b ¦ a≡b ¦ a==b ¦ a^~b ¦ $ \overline{a \oplus b}$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
NOT a || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
not a || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a+b*c || (a+b)⋅c ¦ (a∨b)∧c ¦ (a∨b)∧c ¦ (a||b)&&c ¦ (a|b)&c ¦ $(a+b) \cdot c$ ¦ cnf=false ¦ circ=false ¦ xor=false and=true not=false
a*b+c || a⋅b+c ¦ (a∧b)∨c ¦ (a∧b)∨c ¦ a&&b||c ¦ a&b|c ¦ $a \cdot b+c$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
(a+b)*c || (a+b)⋅c ¦ (a∨b)∧c ¦ (a∨b)∧c ¦ (a||b)&&c ¦ (a|b)&c ¦ $(a+b) \cdot c$ ¦ cnf=false ¦ circ=false ¦ xor=false and=true not=false
~(a+b) || ~(a+b) ¦ ¬(a∨b) ¦ ~(a∨b) ¦ !(a||b) ¦ ~(a|b) ¦ $ \overline{a+b} $ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
~~a || ~~a ¦ ¬¬a ¦ ~~a ¦ !!a ¦ ~~a ¦ $ \overline{ \overline{a} } $ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
a'' || ~~a ¦ ¬¬a ¦ ~~a ¦ !!a ¦ ~~a ¦ $ \overline{ \overline{a} } $ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
(a)' || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a'b' || ~a⋅~b ¦ ¬a∧¬b ¦ ~a∧~b ¦ !a&&!b ¦ ~a&~b ¦ $ \overline{a}  \cdot  \overline{b} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
0 || 0 ¦ 0 ¦ 0 ¦ 0 ¦ 0 ¦ $0$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
1 || 1 ¦ 1 ¦ 1 ¦ 1 ¦ 1 ¦ $1$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
0+1 || 0+1 ¦ 0∨1 ¦ 0∨1 ¦ 0||1 ¦ 0|1 ¦ $0+1$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a+0 || a+0 ¦ a∨0 ¦ a∨0 ¦ a||0 ¦ a|0 ¦ $a+0$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
~0 || ~0 ¦ ¬0 ¦ ~0 ¦ !0 ¦ ~0 ¦ $ \overline{0} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a+b+c || a+b+c ¦ a∨b∨c ¦ a∨b∨c ¦ a||b||c ¦ a|b|c ¦ $a+b+c$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a*b*c || a⋅b⋅c ¦ a∧b∧c ¦ a∧b∧c ¦ a&&b&&c ¦ a&b&c ¦ $a \cdot b \cdot c$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a^b^c || a⊕b⊕c ¦ a⊻b⊻c ¦ a≢b≢c ¦ a!=b!=c ¦ a^b^c ¦ $a \oplus b \oplus c$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a=b=c || a⊙b⊙c ¦ a≡b≡c ¦ a≡b≡c ¦ a==b==c ¦ a^~b^~c ¦ $ \overline{(a \oplus b) \oplus c}$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
a+b^c || a+b⊕c ¦ a∨(b⊻c) ¦ a∨(b≢c) ¦ a||b!=c ¦ a|b^c ¦ $a+b \oplus c$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a^b+c || a⊕b+c ¦ (a⊻b)∨c ¦ (a≢b)∨c ¦ a!=b||c ¦ a^b|c ¦ $a \oplus b+c$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a*b^c || a⋅(b⊕c) ¦ a∧(b⊻c) ¦ a∧(b≢c) ¦ a&&b!=c ¦ a&(b^c) ¦ $a \cdot (b \oplus c)$ ¦ cnf=false ¦ circ=false ¦ xor=true and=true not=false
(a+b)(b+c) || (a+b)⋅(b+c) ¦ (a∨b)∧(b∨c) ¦ (a∨b)∧(b∨c) ¦ (a||b)&&(b||c) ¦ (a|b)&(b|c) ¦ $(a+b) \cdot (b+c)$ ¦ cnf=false ¦ circ=false ¦ xor=false and=true not=false
a(b+c) || a⋅(b+c) ¦ a∧(b∨c) ¦ a∧(b∨c) ¦ a&&(b||c) ¦ a&(b|c) ¦ $a \cdot (b+c)$ ¦ cnf=false ¦ circ=false ¦ xor=false and=true not=false
~a~b || ~a⋅~b ¦ ¬a∧¬b ¦ ~a∧~b ¦ !a&&!b ¦ ~a&~b ¦ $ \overline{a}  \cdot  \overline{b} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
~a+~b || ~a+~b ¦ ¬a∨¬b ¦ ~a∨~b ¦ !a||!b ¦ ~a|~b ¦ $ \overline{a} + \overline{b} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a⋅b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a∧b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a∨b || a+b ¦ a∨b ¦ a∨b ¦ a||b ¦ a|b ¦ $a+b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a⊕b || a⊕b ¦ a⊻b ¦ a≢b ¦ a!=b ¦ a^b ¦ $a \oplus b$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a⊙b || a⊙b ¦ a≡b ¦ a≡b ¦ a==b ¦ a^~b ¦ $ \overline{a \oplus b}$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
a≡b || a⊙b ¦ a≡b ¦ a≡b ¦ a==b ¦ a^~b ¦ $ \overline{a \oplus b}$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
a≢b || a⊕b ¦ a⊻b ¦ a≢b ¦ a!=b ¦ a^b ¦ $a \oplus b$ ¦ cnf=false ¦ circ=false ¦ xor=true and=false not=false
a¬b || a⋅~b ¦ a∧¬b ¦ a∧~b ¦ a&&!b ¦ a&~b ¦ $a \cdot  \overline{b} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
¬a || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a·b || a⋅b ¦ a∧b ¦ a∧b ¦ a&&b ¦ a&b ¦ $a \cdot b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a∥b || a+b ¦ a∨b ¦ a∨b ¦ a||b ¦ a|b ¦ $a+b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a⊤ || a⋅1 ¦ a∧1 ¦ a∧1 ¦ a&&1 ¦ a&1 ¦ $a \cdot 1$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
a⊥ || a⋅0 ¦ a∧0 ¦ a∧0 ¦ a&&0 ¦ a&0 ¦ $a \cdot 0$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
A:q = a+b || q = a+b ¦ q = a∨b ¦ q = a∨b ¦ q = a||b ¦ q = a|b ¦ $q = a+b$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
A:q: a+b || q = a+b ¦ q = a∨b ¦ q = a∨b ¦ q = a||b ¦ q = a|b ¦ $q = a+b$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
A:r = a || r = a ¦ r = a ¦ r = a ¦ r = a ¦ r = a ¦ $r = a$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
A:a = b || a⊙b ¦ a≡b ¦ a≡b ¦ a==b ¦ a^~b ¦ $ \overline{a \oplus b}$ ¦ cnf=false ¦ circ=false ¦ xor=false and=false not=false
q = a+b || ERR off=0 len=1 “q” is not an input variable.
a = || ERR off=2 len=1 Operator “=” missing right operand.
= a || ERR off=0 len=1 Operator “=” missing left operand.
(a || ERR off=0 len=1 No matching closing parenthesis.
a) || ERR off=1 len=1 No matching opening parenthesis.
a + || ERR off=2 len=1 Operator “+” missing right operand.
+ a || ERR off=0 len=1 Operator “+” missing left operand.
a b) || ERR off=3 len=1 No matching opening parenthesis.
() || null
a[0]  || ERR off=0 len=4 “a[0]” is not an input variable.
a[1]+b  || ERR off=0 len=4 “a[1]” is not an input variable.
x[0]  || x[0] ¦ x[0] ¦ x[0] ¦ x[0] ¦ x[0] ¦ $x_{0}$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
x[3]*x[0]  || x[3]⋅x[0] ¦ x[3]∧x[0] ¦ x[3]∧x[0] ¦ x[3]&&x[0] ¦ x[3]&x[0] ¦ $x_{3} \cdot x_{0}$ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
x[9]  || ERR off=0 len=4 “x[9]” is not an input variable.
z || ERR off=0 len=1 “z” is not an input variable.
a$b || ERR off=0 len=3 “a$b” is not an input variable.
a#b || ERR off=1 len=1 Unrecognized characters: ‘#’
a@ || ERR off=1 len=1 Unrecognized characters: ‘@’
a[ || ERR off=0 len=2 No matching brace: “[ ”
a] || ERR off=1 len=1 Missing identifier before subscript: “]”
a[] || EXC StringIndexOutOfBoundsException: Index 4 out of bounds for length 4
a[ ] || EXC StringIndexOutOfBoundsException: Index 5 out of bounds for length 5
a:0  || ERR off=0 len=4 “a[0]” is not an input variable.
a:1 x[2]  || ERR off=0 len=4 “a[1]” is not an input variable.
    || null
a   +   b || a+b ¦ a∨b ¦ a∨b ¦ a||b ¦ a|b ¦ $a+b$ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
~ a || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
- a || ~a ¦ ¬a ¦ ~a ¦ !a ¦ ~a ¦ $ \overline{a} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=false not=false
a - b || a⋅~b ¦ a∧¬b ¦ a∧~b ¦ a&&!b ¦ a&~b ¦ $a \cdot  \overline{b} $ ¦ cnf=true ¦ circ=false ¦ xor=false and=true not=false
"""#
}
