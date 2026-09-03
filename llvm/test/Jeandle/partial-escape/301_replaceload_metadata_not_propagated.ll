; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; ReplaceLoad folds the field load %back onto the previously-stored %src and
; erases it. The erased load's metadata (!nonnull, !dereferenceable,
; !dereferenceable_or_null, !align, !noundef) must NOT be copied onto %src:
; those facts only hold at %back's program point (the nonnull branch), while
; %src also executes on the null-bypass path where the loaded value can be
; null. Copying them would turn that legal path into poison/UB. Graal keeps
; such a refinement sound by wrapping the replacement in a fresh PiNode
; anchored at the replaced node's position (GraphEffectList.replaceAtUsages)
; instead of mutating the replacement; Jeandle drops the refinement.
;
;   %src  = load %external               ; may be null
;   if (%src == null) return             ; bypass path: metadata invalid here
;   store %src into %obj.field           ; nonnull branch only
;   %back = load %obj.field, !nonnull .. ; path-local facts, valid here
;
; PEA must still eliminate the allocation, the store and %back, and RAUW
; %back onto %src, but the surviving %src load must carry none of the five
; metadata kinds.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @consume(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define void @replaceload_metadata_not_propagated(ptr addrspace(1) %external)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %obj = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 30101 to ptr), i32 16, i1 false)
         to label %n unwind label %u
n:
  %src = load atomic ptr addrspace(1), ptr addrspace(1) %external unordered, align 8
  %isnull = icmp eq ptr addrspace(1) %src, null
  br i1 %isnull, label %ret, label %nonnull
nonnull:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %obj, i64 8
  store atomic ptr addrspace(1) %src, ptr addrspace(1) %slot unordered, align 8
  %back = load atomic ptr addrspace(1), ptr addrspace(1) %slot unordered, align 8, !nonnull !{}, !dereferenceable !{i64 8}, !dereferenceable_or_null !{i64 8}, !align !{i64 8}, !noundef !{}
  call void @consume(ptr addrspace(1) %back)
  ret void
ret:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define void @replaceload_metadata_not_propagated(
; CHECK-NOT: jeandle.new_instance
; CHECK: %src = load atomic ptr addrspace(1), ptr addrspace(1) %external unordered, align 8{{$}}
; CHECK-NOT: !nonnull
; CHECK-NOT: !dereferenceable
; CHECK-NOT: !dereferenceable_or_null
; CHECK-NOT: !align
; CHECK-NOT: !noundef
; CHECK-NOT: store atomic
; CHECK: %isnull = icmp eq ptr addrspace(1) %src, null
; CHECK-NEXT: br i1 %isnull, label %ret, label %nonnull
; CHECK: nonnull:
; CHECK-NEXT: call void @consume(ptr addrspace(1) %src)
; CHECK-NEXT: ret void
; CHECK: ret:
; CHECK-NEXT: ret void

!java-method-compilation = !{}
