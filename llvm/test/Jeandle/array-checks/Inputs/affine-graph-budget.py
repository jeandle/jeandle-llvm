import pathlib
import subprocess
import sys

opt, directory = sys.argv[1:]
directory = pathlib.Path(directory)
directory.mkdir(parents=True, exist_ok=True)
for width in (7, 257, 4096):
    entries = "\n".join(f"    i32 {i}, label %incoming{i}" for i in range(width))
    blocks = "\n".join(f"incoming{i}:\n  br label %merge" for i in range(width))
    values = ", ".join(f"[ {i % 7}, %incoming{i} ]" for i in range(width))
    text = f"""define i32 @wide_merge(i32 noundef %choice, i32 noundef %rows, i32 noundef %columns) {{
entry:
  switch i32 %choice, label %incoming0 [
{entries}
  ]
{blocks}
merge:
  %start = phi i32 {values}
  br label %outer
outer:
  %r = phi i32 [ %start, %merge ], [ %r.next, %outer.latch ]
  %offset = mul i32 %r, 7
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %preheader, label %outer.latch
preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %offset, %scaled
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %outer.latch
outer.latch:
  %r.next = add i32 %r, 1
  %again = icmp slt i32 %r.next, %rows
  br i1 %again, label %outer, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}}
!java-method-compilation = !{{}}
"""
    selected = f"""define i32 @selected_merge(i32 noundef %choice, i1 noundef %choose, i32 noundef %columns) {{
entry:
  switch i32 %choice, label %incoming0 [
{entries}
  ]
{blocks}
merge:
  %wide = phi i32 {values}
  %start = select i1 %choose, i32 %wide, i32 0
  %enter = icmp sgt i32 %columns, 0
  br i1 %enter, label %preheader, label %exit
preheader:
  br label %inner
inner:
  %j = phi i32 [ 0, %preheader ], [ %j.next, %body ]
  %scaled = mul i32 %j, 3
  %index = add i32 %start, %scaled
  %ok = icmp ult i32 %index, 1024
  br i1 %ok, label %body, label %fail
body:
  %j.next = add i32 %j, 1
  %more = icmp slt i32 %j.next, %columns
  br i1 %more, label %inner, label %exit
fail:
  ret i32 -1
exit:
  ret i32 0
}}
!java-method-compilation = !{{}}
"""
    for shape, module in (("wide", text), ("selected", selected)):
        source = directory / f"{shape}-{width}.ll"
        source.write_text(module)
        result = subprocess.run([opt, "-S", "-verify-each",
            "-passes=loop-simplify,lcssa,jeandle-affine-check-versioning", str(source)],
            check=True, capture_output=True, text=True, timeout=30)
        (directory / f"{shape}-{width}.out.ll").write_text(result.stdout)
        if width == 7:
            assert "affine.check" in result.stdout, f"small {shape} graph was rejected"
        else:
            assert "affine.check" not in result.stdout, f"{shape} PHI ({width}) exceeded the graph budget"
            assert "%ok = icmp ult" in result.stdout
print("graph budget: small direct/selected PHIs accepted; 257/4096 incoming values retained")
