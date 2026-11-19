from pathlib import Path
import subprocess, random, sys
opt, lli = sys.argv[1:3]
out = Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
# Small controller/index widths expose wrap boundaries in short executions.
preds = [('slt',1),('sle',3),('sgt',-1),('sge',-3),('ne',2),('ult',1),('ule',3),('ugt',-1),('uge',-3)]
# Include folded bounds and the negative same-step recurrences left by IRCE.
preds += [('sgt', -2), ('sgt', -3), ('slt', 1), ('sle', 3)]
header = '''@effects = global i32 0
@len = global i32 32
@fmt = private constant [7 x i8] c"%d:%d\\0A\\00"
declare i32 @printf(ptr, ...)
define noundef range(i32 0, -2147483648) i32 @jeandle.arraylength(ptr addrspace(1) noundef %a) nounwind willreturn memory(read) {
 %v = load i32, ptr @len
 ret i32 %v
}
declare i32 @llvm.experimental.deoptimize.i32(...)
'''
functions=[]
for n,(pred,step) in enumerate(preds):
 index_step = step if n in (9, 10) else 3
 length = '32' if n >= 11 else '%length'
 functions.append(f'''define i32 @loop{n}(i8 noundef %start, i8 noundef %limit, i32 noundef %offset) {{
entry:
 %length = call i32 @jeandle.arraylength(ptr addrspace(1) null)
 br label %loop
loop:
 %i = phi i8 [%start, %entry], [%next, %body]
 %x = phi i32 [%offset, %entry], [%xnext, %body]
 %old = load i32, ptr @effects
 %new = add i32 %old, 1
 store i32 %new, ptr @effects
 %ok = icmp ult i32 %x, {length}
 br i1 %ok, label %body, label %fail
body:
 %xnext = add i32 %x, {index_step}
 %next = add i8 %i, {step}
 %again = icmp {pred} i8 %next, %limit
 br i1 %again, label %loop, label %exit
fail:
 %r = call i32 (...) @llvm.experimental.deoptimize.i32(i32 -26) ["deopt"(i8 %i)]
 ret i32 %r
exit:
 %result = phi i32 [%x, %body]
 ret i32 %result
}}
''')
main=['define i32 @main() {','entry:']
rng=random.Random(1811)
cases=[]
for n,_ in enumerate(preds):
 for j in range(250):
  start=rng.choice([-128,-127,-3,-1,0,1,3,126,127,rng.randint(-128,127)])
  end=rng.choice([-128,-127,-3,-1,0,1,3,126,127,rng.randint(-128,127)])
  offset=rng.choice([-2147483648,-1,0,1,10,31,32,2147483647])
  cases.append((n,start,end,offset))
for j,(n,start,end,offset) in enumerate(cases):
 main.extend([f' store i32 0, ptr @effects',f' %r{j} = call i32 @loop{n}(i8 {start}, i8 {end}, i32 {offset})',f' %e{j} = load i32, ptr @effects', f' %p{j} = call i32 (ptr, ...) @printf(ptr @fmt, i32 %r{j}, i32 %e{j})'])
main+=[' ret i32 0','}']
source=header+'\n'.join(functions+main)+'\n!java-method-compilation = !{}\n'
p=out/'affine-arithmetic.ll'; p.write_text(source)
transformed=subprocess.check_output([str(opt),'-passes=loop-simplify,lcssa,jeandle-affine-check-versioning','-verify-each','-S',str(p)], text=True)
assert transformed.count('.affine.fast:') >= 7
# Replace intrinsic only after the tested pass: the ordinary executable stub
# emulates ending the checked loop and exposes the retained partial effects.
stub='\ndefine i32 @check_failure(...) { ret i32 -26 }\n'
for tag,ir in [('reference',source),('versioned',transformed)]:
 ir=ir.replace('declare i32 @llvm.experimental.deoptimize.i32(...)','').replace('@llvm.experimental.deoptimize.i32','@check_failure')+stub
 f=out/f'affine-arithmetic-{tag}.ll'; f.write_text(ir)
 result=subprocess.check_output([str(lli),str(f)],timeout=90)
 (out/f'affine-arithmetic-{tag}.txt').write_bytes(result)
ref=(out/'affine-arithmetic-reference.txt').read_bytes(); got=(out/'affine-arithmetic-versioned.txt').read_bytes()
assert got==ref, 'versioning changed results or effect counts'
print(f"{len(cases)} differential controller/index overflow cases passed; {transformed.count('.affine.fast:')} versioned loops")
