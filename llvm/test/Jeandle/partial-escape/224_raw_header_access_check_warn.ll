; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-verify-header-access=warn %s 2>&1 | FileCheck %s --check-prefix=WARN
; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" -jeandle-pea-verify-header-access=warn %s 2>/dev/null | FileCheck %s --check-prefix=IR

; Warn mode reports the violation on errs() and keeps the conservative
; behavior: the virtual object is materialized at the access, the
; allocation and the load survive.

@instanceOopDesc.base_offset_in_bytes = private constant i32 12

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)

declare i32 @__gxx_personality_v0(...)

define i32 @test_raw_header_load_warn() gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %hdr = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  %v = load atomic i32, ptr addrspace(1) %hdr unordered, align 4
  ret i32 %v
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; WARN: PEA WARNING: raw object-header memory access (constant byte offset 8 < instanceOopDesc.base_offset_in_bytes 12) in function 'test_raw_header_load_warn'

; IR-LABEL: define i32 @test_raw_header_load_warn
; IR: jeandle.new_instance
; IR: load atomic i32
; IR: ret i32 %v

!java-method-compilation = !{}
