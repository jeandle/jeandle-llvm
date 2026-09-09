; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-verify-header-access=off %s | FileCheck %s

; VMConstants::fromModule verification for instance fields:
;   The module declares the runtime-defined global that HotSpot patches for
;   the first Java-field offset of instanceOopDesc.  With base==12, an access
;   at byte offset 8 is an object-header access, not an instance field.
;
;   PEA must respect the module-provided value instead of falling back to the
;   opt-only InstanceBaseOffset==0 default.  If it ignored this global, the
;   store/load at offset 8 would be treated as a scalar-replaceable field
;   round trip and folded to `ret i32 42`.
;
;   The raw header access used here deliberately violates the frontend
;   invariant that jeandle-pea-verify-header-access polices (Fatal by default
;   in asserts builds); the explicit =off keeps this test focused on the
;   VMConstants::fromModule behavior.

@instanceOopDesc.base_offset_in_bytes = private constant i32 12

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_instance_base_offset_from_module() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u

n:
  %hdr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %hdr unordered, align 4
  %v = load atomic i32, ptr addrspace(1) %hdr unordered, align 4
  ret i32 %v

u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; CHECK-LABEL: define i32 @test_instance_base_offset_from_module
; CHECK: jeandle.new_instance
; CHECK: store atomic i32 42
; CHECK: load atomic i32
; CHECK: ret i32 %v

!java-method-compilation = !{}
