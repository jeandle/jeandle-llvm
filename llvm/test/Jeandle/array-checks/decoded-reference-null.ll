; RUN: opt -passes='expand-narrow-oop-cast,function(instsimplify,simplifycfg)' -verify-each -S %s | FileCheck %s

target datalayout = "e-p:64:64-p1:64:64-p3:32:32"
declare hotspotcc ptr addrspace(1) @jeandle.decode_heap_oop(ptr addrspace(3))
declare hotspotcc ptr addrspace(3) @jeandle.encode_heap_oop(ptr addrspace(1))
declare void @effect(ptr addrspace(1))

; Both incoming decoded values were checked on their corresponding edge.
; The paired PHIs need not be folded or replaced across a safepoint.
define void @forward(ptr addrspace(3) noundef %first, ptr %slot) #0 {
; CHECK-LABEL: define void @forward(
; CHECK: icmp eq ptr addrspace(3) %first, null
; CHECK-NOT: %redundant
; CHECK: call void @effect
; CHECK: icmp eq ptr addrspace(3) %next, null
entry:
  %wide.first = addrspacecast ptr addrspace(3) %first to ptr addrspace(1)
  %empty = icmp eq ptr addrspace(1) %wide.first, null
  br i1 %empty, label %exit, label %loop
loop:
  %narrow = phi ptr addrspace(3) [ %first, %entry ], [ %next, %body ]
  %wide = phi ptr addrspace(1) [ %wide.first, %entry ], [ %wide.next, %body ]
  %element = addrspacecast ptr addrspace(3) %narrow to ptr addrspace(1)
  %redundant = icmp eq ptr addrspace(1) %element, null
  br i1 %redundant, label %fail, label %body
body:
  call void @effect(ptr addrspace(1) %wide)
  %next = load atomic ptr addrspace(3), ptr %slot unordered, align 4
  %wide.next = addrspacecast ptr addrspace(3) %next to ptr addrspace(1)
  %done = icmp eq ptr addrspace(1) %wide.next, null
  br i1 %done, label %exit, label %loop
fail:
  call void @effect(ptr addrspace(1) null)
  ret void
exit:
  ret void
}

; A fresh reload, or an unrelated PHI incoming value, needs its own check.
define i1 @fresh_reload(ptr %slot) #0 {
; CHECK-LABEL: define i1 @fresh_reload(
; CHECK: %first = load atomic
; CHECK: icmp eq ptr addrspace(3) %first, null
; CHECK: %second = load atomic
; CHECK: icmp ne ptr addrspace(3) %second, null
entry:
  %first = load atomic ptr addrspace(3), ptr %slot unordered, align 4
  %wide.first = addrspacecast ptr addrspace(3) %first to ptr addrspace(1)
  %empty = icmp eq ptr addrspace(1) %wide.first, null
  br i1 %empty, label %exit, label %body
body:
  %second = load atomic ptr addrspace(3), ptr %slot unordered, align 4
  %wide.second = addrspacecast ptr addrspace(3) %second to ptr addrspace(1)
  %different = icmp ne ptr addrspace(1) null, %wide.second
  ret i1 %different
exit:
  ret i1 false
}

define i1 @other_address_space(ptr addrspace(4) %p) #0 {
; CHECK-LABEL: define i1 @other_address_space(
; CHECK: addrspacecast ptr addrspace(4) %p to ptr addrspace(1)
; CHECK: icmp eq ptr addrspace(1) %wide, null
  %wide = addrspacecast ptr addrspace(4) %p to ptr addrspace(1)
  %empty = icmp eq ptr addrspace(1) %wide, null
  ret i1 %empty
}

attributes #0 = { "java-method"="0" "use-compressed-oops" }
!java-method-compilation = !{}
