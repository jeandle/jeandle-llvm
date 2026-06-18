; RUN: opt -S -passes="repeated-constant-field-folding" -jeandle-vm-callback-log=%S/Inputs/branch-unlocks-phi.cblog %s 2>&1 | FileCheck %s

; Cascading-fold scenario the bare ConstantFieldFolding pass cannot crack:
;
;   Root (oop 0) holds: FLAG at off 12 (int, value 0)
;                       PRIMARY at off 16 (Object, oop 1)
;                       SECONDARY at off 20 (Object, oop 2)
;   Child A (oop 1) holds: VAL at off 8 (int, value 42)
;   Child B (oop 2) holds: VAL at off 8 (int, value 99)
;
; Java-level shape:
;   int v;
;   if (Root.FLAG == 0) v = Root.PRIMARY.VAL;
;   else                v = Root.SECONDARY.VAL;
;   return v;
;
; In a single CFF invocation, the merge PHI receives loads from two distinct
; oop_handle globals (1 and 2), the lattice meets to Bottom, and the final
; val load cannot be folded. The wrapper folds FLAG to 0, SCCP makes the
; branch unconditional, SimplifyCFG drops the right side, and the second
; CFF call sees the PHI degenerated to a single Constant{1} and folds VAL
; to 42.

@oop_handle_Root_0 = external global ptr addrspace(1)

define i32 @test() gc "hotspotgc" {
entry:
  %base = load ptr addrspace(1), ptr @oop_handle_Root_0
  %flag.addr = getelementptr i8, ptr addrspace(1) %base, i64 12
  %flag = load i32, ptr addrspace(1) %flag.addr
  %cond = icmp eq i32 %flag, 0
  br i1 %cond, label %left, label %right

left:
  %primary.addr = getelementptr i8, ptr addrspace(1) %base, i64 16
  %primary = load ptr addrspace(1), ptr addrspace(1) %primary.addr
  br label %merge

right:
  %secondary.addr = getelementptr i8, ptr addrspace(1) %base, i64 20
  %secondary = load ptr addrspace(1), ptr addrspace(1) %secondary.addr
  br label %merge

merge:
  %obj = phi ptr addrspace(1) [ %primary, %left ], [ %secondary, %right ]
  %val.addr = getelementptr i8, ptr addrspace(1) %obj, i64 8
  %val = load i32, ptr addrspace(1) %val.addr
  ret i32 %val
}

; CHECK-LABEL: define i32 @test()
; CHECK-NOT: phi
; CHECK-NOT: load i32
; CHECK: ret i32 42

!java-method-compilation = !{}
