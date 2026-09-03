; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s

; Oversized-field guard: a field wider than 255 bytes (e.g. <32 x i64> = 256
; bytes) does not fit FieldDesc::ByteSize (uint8_t — it would truncate to 0
; and never overlap, corrupting the field model). getOrCreateFieldIndex bails
; (-1) and the object is kept real.

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare i32 @__gxx_personality_v0(...)

define void @oversized_field(<32 x i64> %v) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 512, i1 false)
         to label %n unwind label %u
n:
  %f = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store <32 x i64> %v, ptr addrspace(1) %f, align 8
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The allocation and the oversized store both survive (PEA bails).
; CHECK-LABEL: define void @oversized_field(
; CHECK: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; CHECK: store <32 x i64> %v, ptr addrspace(1) %f, align 8
; CHECK: ret void

!java-method-compilation = !{}
