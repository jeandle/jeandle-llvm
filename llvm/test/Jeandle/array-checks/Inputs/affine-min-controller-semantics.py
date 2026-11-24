from itertools import product
from pathlib import Path
import subprocess
import sys

opt, lli = sys.argv[1:3]
out = Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
predicates = ('sgt', 'sge', 'ugt', 'uge', 'ne')


def make_loop(name, bits, pred, bounded=False):
    ty = f'i{bits}'
    argty = 'i32' if bounded else ty
    casts = (f' %init = sext i32 %start to {ty}\n'
             f' %bound = sext i32 %limit to {ty}\n') if bounded else ''
    init, limit = ('%init', '%bound') if bounded else ('%start', '%limit')
    return f'''define i32 @{name}({argty} noundef %start, {argty} noundef %limit, i32 noundef %offset) {{
entry:
{casts} %first = sext i32 %offset to i64
 br label %loop
loop:
 %i = phi {ty} [{init}, %entry], [%next, %latch]
 %x = phi i64 [%first, %entry], [%xnext, %latch]
 %sum = phi i32 [0, %entry], [%sum.next, %latch]
 %fuel = phi i32 [0, %entry], [%fuel.next, %latch]
 %old = load i32, ptr @effects
 %new = add i32 %old, 1
 store i32 %new, ptr @effects
 %ok = icmp ult i64 %x, 32
 br i1 %ok, label %body, label %fail
body:
 %narrow = trunc i64 %x to i32
 %sum.next = add i32 %sum, %narrow
 %xnext = add i64 %x, 1
 %next = add {ty} %i, {-(1 << (bits - 1))}
 %fuel.next = add i32 %fuel, 1
 %has.fuel = icmp ult i32 %fuel.next, 8
 br i1 %has.fuel, label %latch, label %exhausted
latch:
 %again = icmp {pred} {ty} %next, {limit}
 br i1 %again, label %loop, label %exit
fail:
 %failed = add i32 %sum, 10000
 ret i32 %failed
exit:
 %finished = add i32 %sum.next, 20000
 ret i32 %finished
exhausted:
 %stopped = add i32 %sum.next, 30000
 ret i32 %stopped
}}
'''


def reference(bits, pred, start, limit, offset):
    # Execute the modular loop directly; do not reproduce trip-count proofs.
    modulus = 1 << bits
    minimum = -(1 << (bits - 1))
    i, x, total = start, offset, 0
    for effects in range(1, 9):
        if not 0 <= x < 32:
            return 10000 + total, effects
        total += x
        x += 1
        i = (i + minimum) % modulus
        if i >= modulus // 2:
            i -= modulus
        if effects == 8:
            return 30000 + total, effects
        if pred == 'ne':
            again = i != limit
        else:
            left, right = (i % modulus, limit % modulus) if pred[0] == 'u' else (i, limit)
            again = left >= right if pred.endswith('ge') else left > right
        if not again:
            return 20000 + total, effects


# Hand-checked fixtures protect the independent interpreter's exit ordering.
assert reference(32, 'sgt', 0, -(1 << 31), 0) == (20000, 1)
assert reference(32, 'sgt', -(1 << 31), -(1 << 31), 31) == (10031, 2)
assert reference(32, 'ne', -(1 << 31), -(1 << 31), 0) == (20001, 2)
assert reference(64, 'sge', 0, -(1 << 63), 0) == (30028, 8)

functions, cases = [], []
for bits in (32, 64):
    minimum, maximum = -(1 << (bits - 1)), (1 << (bits - 1)) - 1
    edges = (minimum, minimum + 1, -1, 0, 1, maximum - 1, maximum)
    for pred in predicates:
        name = f'min_{bits}_{pred}'
        functions.append(make_loop(name, bits, pred))
        for start, limit, offset in product(edges, edges, (-1, 0, 30, 31, 32)):
            cases.append((name, bits, pred, start, limit, offset))

# Narrow operands do not make the positive magnitude of LONG_MIN fit in i64.
functions.append(make_loop('bounded_min_64', 64, 'sgt', bounded=True))
main = ['define i32 @main() {', 'entry:']
expected = []
exit_kinds = set()
for n, (name, bits, pred, start, limit, offset) in enumerate(cases):
    result, effects = reference(bits, pred, start, limit, offset)
    exit_kinds.add(result // 10000)
    expected.append(f'{result}:{effects}\n')
    main.extend([' store i32 0, ptr @effects',
                 f' %r{n} = call i32 @{name}(i{bits} {start}, i{bits} {limit}, i32 {offset})',
                 f' %e{n} = load i32, ptr @effects',
                 f' %p{n} = call i32 (ptr, ...) @printf(ptr @fmt, i32 %r{n}, i32 %e{n})'])
main.extend([' ret i32 0', '}'])
assert exit_kinds == {1, 2, 3}, 'missing check, latch or fuel exit coverage'
source = (r'''@effects = global i32 0
@fmt = private constant [7 x i8] c"%d:%d\0A\00"
declare i32 @printf(ptr, ...)
''' + '\n'.join(functions + main) + '\n!java-method-compilation = !{}\n')
input_file = out / 'min-controller.ll'
input_file.write_text(source)
transformed = subprocess.check_output([
    opt, '-passes=loop-simplify,lcssa,jeandle-affine-check-versioning',
    '-verify-each', '-S', str(input_file)], text=True)
for bits in (32, 64):
    for pred in predicates:
        name = f'min_{bits}_{pred}'
        body = transformed.split(f'define i32 @{name}(')[1].split('\n}\n')[0]
        assert '.affine.fast' in body, f'missing version for {name}'
        guard = body.split('loop.affine.check:')[1].split('br i1')[0]
        assert f'icmp ult i{64 if bits == 32 else 128}' in guard, name
body = transformed.split('define i32 @bounded_min_64(')[1].split('\n}\n')[0]
assert '.affine.fast' in body, 'missing bounded MIN version'
guard = body.split('loop.affine.check:')[1].split('br i1')[0]
assert 'i128' in guard, 'LONG_MIN magnitude narrowed to i64'

expected_bytes = ''.join(expected).encode()
(out / 'min-controller-expected.txt').write_bytes(expected_bytes)
for tag, ir in (('reference', source), ('versioned', transformed)):
    path = out / f'min-controller-{tag}.ll'
    path.write_text(ir)
    result = subprocess.check_output([lli, str(path)], timeout=90)
    (out / f'min-controller-{tag}.txt').write_bytes(result)
    assert result == expected_bytes, f'{tag} changed results, exits or partial effects'
print(f'{len(cases)} MIN-controller differential cases passed; 11 versioned loops')
