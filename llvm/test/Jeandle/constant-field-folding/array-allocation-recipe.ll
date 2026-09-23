; RUN: opt -S -verify-each -passes='repeated-constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/array-allocation-recipe.cblog %s | FileCheck %s -DKLASS=123456 -DSHIFT=2 -DHEADER=16 -DLIMIT=262144
; RUN: opt -S -verify-each -passes='repeated-constant-field-folding' -jeandle-vm-callback-log=%S/Inputs/array-allocation-reference-recipe.cblog %s | FileCheck %s -DKLASS=234567 -DSHIFT=3 -DHEADER=24 -DLIMIT=131072
;
; Model the frontend's dynamic allocation recipe. The VM supplies the encoded
; layout and its masks; LLVM need not know HotSpot's layout constants. Folding
; load_klass/layout_helper must specialize operands without replacing the real
; allocation klass or losing the exception edge/deopt state. No allocation
; specialization pass is needed. Unknown layouts must stay executable.

@oop_handle_Test_0 = external global ptr addrspace(1)
declare hotspotcc ptr @jeandle.load_klass(ptr addrspace(1))
declare hotspotcc i32 @jeandle.layout_helper(ptr)
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32)
declare i32 @personality(...)
declare void @observe_exception()

define hotspotcc ptr addrspace(1) @known_layout(i32 %length) #0 gc "hotspotgc" personality ptr @personality {
entry:
  %obj = load ptr addrspace(1), ptr @oop_handle_Test_0
  %klass = call hotspotcc ptr @jeandle.load_klass(ptr addrspace(1) %obj)
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  %hs = lshr i32 %layout, 16
  %header = and i32 %hs, 255
  %shift = and i32 %layout, 63
  %body = shl i32 %length, %shift
  %total = add i32 %body, %header
  %rounded = add i32 %total, 7
  %size = and i32 %rounded, -8
  %scale = sub i32 3, %shift
  %limit = shl i32 131072, %scale
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr %klass, i32 %length, i32 %size, i32 %header, i32 %limit) [ "deopt"(ptr addrspace(1) %obj) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %array
exception:
  %ex = landingpad { ptr, i32 } cleanup
  call void @observe_exception()
  resume { ptr, i32 } %ex
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @known_layout(
; CHECK-NOT: call hotspotcc {{.*}}@jeandle.{{(load_klass|layout_helper)}}
; CHECK: %body = shl i32 %length, [[SHIFT]]
; CHECK: %total = add i32 %body, [[HEADER]]
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 [[KLASS]] to ptr), i32 %length, i32 %size, i32 [[HEADER]], i32 [[LIMIT]]) [ "deopt"(ptr addrspace(1) %obj) ]
; CHECK: to label %normal unwind label %exception
; CHECK: ret ptr addrspace(1) %array
; CHECK: resume { ptr, i32 } %ex

define hotspotcc ptr addrspace(1) @dynamic(ptr %a, ptr %b, i1 %which, i32 %length) #0 gc "hotspotgc" personality ptr @personality {
entry:
  br i1 %which, label %left, label %right
left:
  br label %merge
right:
  br label %merge
merge:
  %klass = phi ptr [ %a, %left ], [ %b, %right ]
  %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
  %hs = lshr i32 %layout, 16
  %header = and i32 %hs, 255
  %shift = and i32 %layout, 63
  %body = shl i32 %length, %shift
  %total = add i32 %body, %header
  %rounded = add i32 %total, 7
  %size = and i32 %rounded, -8
  %scale = sub i32 3, %shift
  %limit = shl i32 131072, %scale
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr %klass, i32 %length, i32 %size, i32 %header, i32 %limit) [ "deopt"(i32 %length) ] to label %normal unwind label %exception
normal:
  ret ptr addrspace(1) %array
exception:
  %ex = landingpad { ptr, i32 } cleanup
  call void @observe_exception()
  resume { ptr, i32 } %ex
}

; CHECK-LABEL: define hotspotcc ptr addrspace(1) @dynamic(
; CHECK: %klass = phi ptr [ %a, %left ], [ %b, %right ]
; CHECK: %layout = call hotspotcc i32 @jeandle.layout_helper(ptr %klass)
; CHECK: %body = shl i32 %length, %shift
; CHECK: %limit = shl i32 131072, %scale
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr %klass, i32 %length, i32 %size, i32 %header, i32 %limit) [ "deopt"(i32 %length) ]
; CHECK: to label %normal unwind label %exception
; CHECK: ret ptr addrspace(1) %array

attributes #0 = { "java-method"="1" }
!java-method-compilation = !{}
