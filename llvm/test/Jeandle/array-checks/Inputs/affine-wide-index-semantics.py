from pathlib import Path
import re
import subprocess
import sys

opt, lli, fixture, directory = sys.argv[1:]
out = Path(directory)
out.mkdir(parents=True, exist_ok=True)
source = Path(fixture).read_text()
source = re.sub(r'^declare .*@jeandle.arraylength.*$', '''define noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr noundef %a) {
  ret i32 32
}''', source, flags=re.M)
source = source.replace('declare void @effect(i32, i64)', '''@hash = global i64 0
@bad = global i32 0
@fmt = private constant [12 x i8] c"%d:%lld:%d\\0A\\00"
declare i32 @printf(ptr, ...)
define void @effect(i32 %index, i64 %wide) {
  %expected = zext i32 %index to i64
  %different = icmp ne i64 %expected, %wide
  %error = zext i1 %different to i32
  %oldbad = load i32, ptr @bad
  %newbad = or i32 %oldbad, %error
  store i32 %newbad, ptr @bad
  %old = load i64, ptr @hash
  %product = mul i64 %old, 131
  %signed = sext i32 %index to i64
  %mixed = add i64 %wide, %signed
  %new = add i64 %product, %mixed
  store i64 %new, ptr @hash
  ret void
}''')
main = ['define i32 @main() {', 'entry:']
cases = []
for name, direction in [('checked_extension', 1), ('checked_extension_reverse', -1),
                        ('checked_extension_dynamic', 1), ('checked_signed_extension', 1)]:
    for init in [-2147483648, -1073741824, -3, 0, 1, 1073741824, 2147483643, 2147483647]:
        for count in [0, 1, 3]:
            end = init + direction * count
            if not -2147483648 <= end <= 2147483647:
                continue
            for offset in [-2147483648, -1, 0, 1, 16, 31, 32, 2147483647]:
                for scale in ([-2147483648, -5, -2, 0, 2, 5, 2147483647]
                              if name.endswith('_dynamic') else [5]):
                    cases.append((name, init, end, offset, scale))
for n, (name, init, end, offset, scale) in enumerate(cases):
    args = f'ptr inttoptr (i64 1 to ptr), i32 {init}, i32 {end}, i32 {offset}'
    if name.endswith('_dynamic'):
        args += f', i32 {scale}'
    main += ['store i64 0, ptr @hash', 'store i32 0, ptr @bad',
             f'%r{n} = call i32 @{name}({args})',
             f'%h{n} = load i64, ptr @hash', f'%b{n} = load i32, ptr @bad',
             f'%p{n} = call i32 (ptr, ...) @printf(ptr @fmt, i32 %r{n}, i64 %h{n}, i32 %b{n})']
main += ['ret i32 0', '}']
source += '\n'.join(main) + '\n'
original = out / 'original.ll'
original.write_text(source)
optimized = out / 'optimized.ll'
subprocess.run([opt, '-passes=loop-simplify,lcssa,jeandle-affine-check-versioning,instcombine,simplifycfg',
                '-verify-each', '-S', str(original), '-o', str(optimized)], check=True)
assert optimized.read_text().count('phi i64') >= 4, 'wide checked-index paths were not generated'
expected = subprocess.check_output([lli, str(original)], timeout=60)
actual = subprocess.check_output([lli, str(optimized)], timeout=60)
(out / 'original.txt').write_bytes(expected)
(out / 'optimized.txt').write_bytes(actual)
assert expected == actual, 'results, partial side effects or extended indices differ'
assert len(actual.splitlines()) == len(cases)
assert all(line.endswith(b':0') for line in actual.splitlines()), 'wide index differs from zero-extended Java index'
print('matched', len(cases), 'forward/reverse/dynamic cases with wrapping starts, failures and partial effects')
