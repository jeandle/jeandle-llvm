from pathlib import Path
import random
import subprocess
import sys

opt, lli = sys.argv[1:3]
out = Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
header = r'''@effects = global i32 0
@fmt = private constant [7 x i8] c"%d:%d\0A\00"
declare i32 @printf(ptr, ...)
'''
functions = []
# A real 64-bit controller with independently bounded operands should use i64
# entry math. Full-width inputs must retain i128, including unsigned limits.
predicates = [('ult', 1), ('ule', 3), ('ugt', -1), ('uge', -3),
              ('slt', 1), ('sle', 3), ('sgt', -1), ('sge', -3), ('ne', 2)]
for bounded in (True, False):
    for pred, step in predicates:
        n = len(functions)
        ty = 'i32' if bounded else 'i64'
        ext = 'zext' if pred.startswith('u') else 'sext'
        casts = (f' %init = {ext} i32 %start to i64\n'
                 f' %bound = {ext} i32 %limit to i64\n'
                 ' %first = sext i32 %offset to i64\n'
                 ' %stride = sext i32 %scale to i64\n') if bounded else ''
        init, bound, first, stride = ('%init', '%bound', '%first', '%stride') if bounded else ('%start', '%limit', '%offset', '%scale')
        functions.append(f'''define i32 @loop{n}({ty} noundef %start, {ty} noundef %limit, {ty} noundef %offset, {ty} noundef %scale) {{
entry:
{casts} br label %loop
loop:
 %i = phi i64 [{init}, %entry], [%next, %body]
 %x = phi i64 [{first}, %entry], [%xnext, %body]
 %sum = phi i32 [0, %entry], [%sum.next, %body]
 %old = load i32, ptr @effects
 %new = add i32 %old, 1
 store i32 %new, ptr @effects
 %ok = icmp ult i64 %x, 32
 br i1 %ok, label %body, label %fail
body:
 %narrow = trunc i64 %x to i32
 %sum.next = add i32 %sum, %narrow
 %xnext = add i64 %x, {stride}
 %next = add i64 %i, {step}
 %again = icmp {pred} i64 %next, {bound}
 br i1 %again, label %loop, label %exit
fail:
 ret i32 %sum
exit:
 ret i32 %sum.next
}}
''')
main = ['define i32 @main() {', 'entry:']
rng = random.Random(674143)
cases = []
for n in range(len(functions)):
    bits = 32 if n < 9 else 64
    minimum, maximum = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    pred, step = predicates[n % 9]
    edges = [minimum, minimum + 1, -1, 0, 1, maximum - 1, maximum]
    for j in range(200):
        start = rng.choice(edges + [rng.randint(-32, 32)])
        limit = rng.choice(edges + [rng.randint(-32, 32)])
        offset = rng.choice(edges + [2, 16, 31, 32])
        scale = rng.choice(edges + [-3, 3])
        if j % 4 == 0:
            # Guaranteed finite, in-range runs also exercise the fast entry.
            start = rng.choice([minimum + 64, 64, maximum - 64])
            limit = start + step * rng.randint(1, 8)
            offset = 16
            scale = rng.choice([-1, 0, 1])
        # Nonzero scales fail a check quickly even when a wrapping controller
        # would otherwise take an enormous number of iterations.
        if scale == 0 and j % 4 != 0:
            scale = 1
        cases.append((n, bits, start, limit, offset, scale))
for j, (n, bits, start, limit, offset, scale) in enumerate(cases):
    ty = f'i{bits}'
    args = ', '.join(f'{ty} {v}' for v in (start, limit, offset, scale))
    main.extend([' store i32 0, ptr @effects',
                 f' %r{j} = call i32 @loop{n}({args})',
                 f' %e{j} = load i32, ptr @effects',
                 f' %p{j} = call i32 (ptr, ...) @printf(ptr @fmt, i32 %r{j}, i32 %e{j})'])
main.extend([' ret i32 0', '}'])
source = header + '\n'.join(functions + main) + '\n!java-method-compilation = !{}\n'
p = out / 'wide.ll'
p.write_text(source)
transformed = subprocess.check_output([opt, '-passes=loop-simplify,lcssa,jeandle-affine-check-versioning', '-verify-each', '-S', str(p)], text=True)
for n in range(18):
    body = transformed.split(f'define i32 @loop{n}(')[1].split('\n}\n')[0]
    guard = body.split('loop.affine.check:')[1].split('br i1')[0]
    assert '.affine.fast' in body, f'missing version for loop{n}'
    # Bounded ranges around both controller extremes can still require i128
    # when they include all unsigned i32 values and a negative NE endpoint.
    if n == 4:
        assert 'i128' not in guard and 'icmp ult i64' in guard
    if n >= 9:
        assert 'i128' in guard, f'full-width inputs narrowed in loop{n}'
results = []
for tag, ir in [('reference', source), ('versioned', transformed)]:
    f = out / f'wide-{tag}.ll'
    f.write_text(ir)
    result = subprocess.check_output([lli, str(f)], timeout=90)
    (out / f'wide-{tag}.txt').write_bytes(result)
    results.append(result)
assert results[0] == results[1], 'versioning changed sums or partial effects'
print(f'{len(cases)} wide-input differential cases passed; 18 versioned loops')
