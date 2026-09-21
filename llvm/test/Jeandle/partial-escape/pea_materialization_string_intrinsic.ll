; RUN: opt -S -verify-each -jeandle-pea-iterations=1 -passes='function(instcombine,gvn,adce,simplifycfg,partial-escape-iterative)' %s | FileCheck %s --implicit-check-not='store atomic <'
; RUN: opt -S -verify-each -jeandle-pea-iterations=4 -passes='function(instcombine,gvn,adce,simplifycfg,partial-escape-iterative)' %s -o %t.once
; RUN: FileCheck %s --implicit-check-not='store atomic <' < %t.once
; RUN: opt -S -verify-each -jeandle-pea-iterations=4 -passes='function(instcombine,gvn,adce,simplifycfg,partial-escape-iterative,partial-escape-iterative)' %s -o %t.twice
; RUN: diff %t.once %t.twice

; The marker materializes only its virtual operands and survives every round.
; Use callback-free instance allocations to isolate this PEA contract. String
; jtreg tests exercise the frontend producers with real Java arrays.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @llvm.sideeffect()
attributes #0 = { memory(inaccessiblemem: readwrite) }
declare i32 @__gxx_personality_v0(...)
declare void @sink(ptr addrspace(1))

define i32 @two_virtual_objects(<8 x i8> %bytes) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1001 to ptr), i32 32, i1 false)
      to label %source_allocated unwind label %unwind
source_allocated:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1002 to ptr), i32 32, i1 false)
      to label %destination_allocated unwind label %unwind
destination_allocated:
  %other = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1003 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %srcp = getelementptr i8, ptr addrspace(1) %src, i64 16
  %dstp = getelementptr i8, ptr addrspace(1) %dst, i64 16
  %otherp = getelementptr i8, ptr addrspace(1) %other, i64 16
  store i64 42, ptr addrspace(1) %srcp, align 8
  store i32 37, ptr addrspace(1) %otherp, align 4
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
  store <8 x i8> %bytes, ptr addrspace(1) %dstp, align 1
  call void @sink(ptr addrspace(1) %src)
  call void @sink(ptr addrspace(1) %dst)
  %result = load i32, ptr addrspace(1) %otherp, align 4
  ret i32 %result
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @two_virtual_objects(
; CHECK-COUNT-2: {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: store atomic i64 42,
; CHECK: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %dst) ]
; CHECK-NEXT: store <8 x i8> %bytes, ptr addrspace(1) %dstp, align 1
; CHECK: ret i32 37

define void @duplicate_operands() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1004 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 16
  store i32 11, ptr addrspace(1) %slot, align 4
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %obj, ptr addrspace(1) %obj) ]
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %obj, ptr addrspace(1) %obj) ]
  call void @sink(ptr addrspace(1) %obj)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @duplicate_operands(
; CHECK: {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK-NOT: @jeandle.new_instance
; CHECK: store atomic i32 11,
; CHECK-NEXT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %obj, ptr addrspace(1) %obj) ]
; CHECK-NEXT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %obj, ptr addrspace(1) %obj) ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %obj)
; CHECK-NEXT: ret void

define void @virtual_source(ptr addrspace(1) %external) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %src = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1005 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %src, i64 16
  store i32 13, ptr addrspace(1) %slot, align 4
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %external) ]
  call void @sink(ptr addrspace(1) %src)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @virtual_source(
; CHECK: store atomic i32 13,
; CHECK-NEXT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %src, ptr addrspace(1) %external) ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %src)

define void @virtual_destination(ptr addrspace(1) %external) gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %dst = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1006 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %dst, i64 16
  store i32 17, ptr addrspace(1) %slot, align 4
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %external, ptr addrspace(1) %dst) ]
  call void @sink(ptr addrspace(1) %dst)
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @virtual_destination(
; CHECK: store atomic i32 17,
; CHECK-NEXT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %external, ptr addrspace(1) %dst) ]
; CHECK-NEXT: call void @sink(ptr addrspace(1) %dst)

; The marker must be a semantic use even without a later escaping call.
define void @marker_only_use() gc "hotspotgc"
    personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
      ptr inttoptr (i64 1007 to ptr), i32 32, i1 false)
      to label %body unwind label %unwind
body:
  %slot = getelementptr i8, ptr addrspace(1) %obj, i64 16
  store i32 23, ptr addrspace(1) %slot, align 4
  call void @llvm.sideeffect() #0 [ "jeandle.pea.materialize"(ptr addrspace(1) %obj, ptr addrspace(1) %obj) ]
  ret void
unwind:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @marker_only_use(
; CHECK: {{call|invoke}} hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store atomic i32 23,
; CHECK-NEXT: call void @llvm.sideeffect(){{.*}}[ "jeandle.pea.materialize"(ptr addrspace(1) %obj, ptr addrspace(1) %obj) ]
; CHECK-NEXT: ret void

!java-method-compilation = !{}
