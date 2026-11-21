; RUN: opt -passes='jeandle-array-length-optimization' -verify-each -S %s | FileCheck %s --implicit-check-not='phi i32'

declare i32 @jeandle.arraylength(ptr addrspace(1)) nounwind
declare void @effect(i32)

; A complete but oversized backward slice must fail before inserting PHIs.
define i32 @block_budget(ptr addrspace(1) noundef %a, i1 %which) {
; CHECK-LABEL: define i32 @block_budget(
; CHECK: %la = call i32 @jeandle.arraylength
; CHECK: %lb = call i32 @jeandle.arraylength
; CHECK: join:
; CHECK-NOT: phi i32
; CHECK: %again = call i32 @jeandle.arraylength
; CHECK-NEXT: ret i32 %again
entry:
  br i1 %which, label %left, label %right
left:
  %la = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %la)
  br label %path0
right:
  %lb = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  call void @effect(i32 %lb)
  br label %join
path0:
  br label %path1
path1:
  br label %path2
path2:
  br label %path3
path3:
  br label %path4
path4:
  br label %path5
path5:
  br label %path6
path6:
  br label %path7
path7:
  br label %path8
path8:
  br label %path9
path9:
  br label %path10
path10:
  br label %path11
path11:
  br label %path12
path12:
  br label %path13
path13:
  br label %path14
path14:
  br label %path15
path15:
  br label %path16
path16:
  br label %path17
path17:
  br label %path18
path18:
  br label %path19
path19:
  br label %path20
path20:
  br label %path21
path21:
  br label %path22
path22:
  br label %path23
path23:
  br label %path24
path24:
  br label %path25
path25:
  br label %path26
path26:
  br label %path27
path27:
  br label %path28
path28:
  br label %path29
path29:
  br label %path30
path30:
  br label %path31
path31:
  br label %path32
path32:
  br label %path33
path33:
  br label %path34
path34:
  br label %path35
path35:
  br label %path36
path36:
  br label %path37
path37:
  br label %path38
path38:
  br label %path39
path39:
  br label %path40
path40:
  br label %path41
path41:
  br label %path42
path42:
  br label %path43
path43:
  br label %path44
path44:
  br label %path45
path45:
  br label %path46
path46:
  br label %path47
path47:
  br label %path48
path48:
  br label %path49
path49:
  br label %path50
path50:
  br label %path51
path51:
  br label %path52
path52:
  br label %path53
path53:
  br label %path54
path54:
  br label %path55
path55:
  br label %path56
path56:
  br label %path57
path57:
  br label %path58
path58:
  br label %path59
path59:
  br label %path60
path60:
  br label %path61
path61:
  br label %path62
path62:
  br label %path63
path63:
  br label %path64
path64:
  br label %path65
path65:
  br label %join
join:
  %again = call i32 @jeandle.arraylength(ptr addrspace(1) noundef %a)
  ret i32 %again
}

!java-method-compilation = !{}
