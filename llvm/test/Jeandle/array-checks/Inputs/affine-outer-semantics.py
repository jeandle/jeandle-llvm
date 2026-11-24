from pathlib import Path
import itertools
import subprocess
import sys

opt, lli = sys.argv[1:3]
out = Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
source = '''@effects = global i32 0
@fmt = private constant [7 x i8] c"%d:%d\\0A\\00"
declare i32 @printf(ptr, ...)
define i32 @nested(i32 noundef %rows, i32 noundef %columns,
                   i32 noundef %stride, i32 noundef %seed) {
entry:
  %enter = icmp sgt i32 %rows, 0
  br i1 %enter, label %outer, label %exit
outer:
  %r = phi i32 [ 0, %entry ], [ %r.next, %outer.latch ]
  %product = mul i32 %r, %stride
  %offset = add i32 %product, %seed
  %parity = and i32 %r, 1
  %even = icmp eq i32 %parity, 0
  %positive = icmp sgt i32 %columns, 0
  %run = and i1 %even, %positive
  br i1 %run, label %preheader, label %outer.latch
preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %scaled, %offset
  %old = load i32, ptr @effects
  %new = add i32 %old, 1
  store i32 %new, ptr @effects
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add nuw nsw i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -26
exit:
  ret i32 42
}
'''
# Odd rows skip the inner loop: INT_MIN * even-row wraps back to zero.
# The entry guard must use this iteration's actual modular offset.
cases = list(itertools.product([0, 1, 5], [-1, 0, 1, 32],
                              [-2147483648, -1073741824, -7, 0, 3, 7, 1073741824, 2147483647],
                              [-2147483648, -1, 0, 1, 31, 1023, 1024, 2147483647]))
main = ['define i32 @main() {', 'entry:']
for n, (rows, columns, stride, seed) in enumerate(cases):
    main += ['store i32 0, ptr @effects',
             f'%r{n} = call i32 @nested(i32 {rows}, i32 {columns}, i32 {stride}, i32 {seed})',
             f'%e{n} = load i32, ptr @effects',
             f'%p{n} = call i32 (ptr, ...) @printf(ptr @fmt, i32 %r{n}, i32 %e{n})']
main += ['ret i32 0', '}']
source += '\n'.join(main) + '\n!java-method-compilation = !{}\n'
p = out / 'outer.ll'
p.write_text(source)
transformed = subprocess.check_output([opt, '-passes=loop-simplify,lcssa,jeandle-affine-check-versioning',
                                       '-verify-each', '-S', str(p)], text=True)
assert 'inner.affine.fast:' in transformed
assert 'sext i32 %offset to i64' in transformed
reference = None
for tag, ir in [('reference', source), ('versioned', transformed)]:
    p = out / (tag + '.ll')
    p.write_text(ir)
    result = subprocess.check_output([lli, str(p)], timeout=120)
    (out / (tag + '.txt')).write_bytes(result)
    if reference is None:
        reference = result
    else:
        assert result == reference, 'outer modular values or partial effects changed'
print(f'{len(cases)} nested modular-start/effect differential cases passed')
