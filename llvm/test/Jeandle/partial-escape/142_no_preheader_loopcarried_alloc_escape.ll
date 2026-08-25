; RUN: opt -S -passes="require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=NOPRE
; RUN: opt -S -passes="loop-simplify,require<partial-escape-analysis>,partial-escape-transform" %s | FileCheck %s --check-prefix=FIXPOINT
;
; Regression guard for a PEA soundness hazard that affects BOTH the !Preheader
; single-pass path AND the fixpoint path. A loop-LOCAL object %X allocated in
; the body is carried across the back-edge by the header PHI %px and observed
; at the loop exit (load %px's field -> @use).
;
; The hazard: the in-pass header merge (header first in RPO) runs before %X
; is virtualized, so the back-edge slot of %px cannot resolve yet. If the PHI
; is skipped there, PEA never sees %X escape via the PHI, classifies it
; NeverEscapes, and the transform RAUWs %X -> poison, leaking poison to @use.
;
; The post-body merge (run AFTER the body) persists its Case-A materialization
; at the back-edge pred, so %X is never eliminated. This accumulation shape
; references the previous iteration's field (%pv = load %px.f), so %X is
; conservatively classified AlwaysEscapes here and the original alloc + stores
; survive unchanged -- the key assertion is NO poison and the alloc survives.
; See 143_* for the simpler shape that achieves back-edge materialization
; (PartiallyEscapes).

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare void @use(i32)
declare i32 @__gxx_personality_v0(...)

define void @test_142_loopcarried_local(i1 %p, i32 %n) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  br i1 %p, label %fwd_a, label %fwd_b
fwd_a:
  br label %hdr
fwd_b:
  br label %hdr
hdr:
  %i = phi i32 [ 0, %fwd_a ], [ 0, %fwd_b ], [ %i1, %latch ]
  %px = phi ptr addrspace(1) [ null, %fwd_a ], [ null, %fwd_b ], [ %X, %latch ]
  %c = icmp slt i32 %i, %n
  br i1 %c, label %body, label %exit
body:
  %X = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 5555 to ptr), i32 16, i1 false)
          to label %bcont unwind label %u
bcont:
  %sf = getelementptr inbounds i8, ptr addrspace(1) %X, i64 8
  %isnull = icmp eq ptr addrspace(1) %px, null
  br i1 %isnull, label %init, label %acc
init:
  store atomic i32 1, ptr addrspace(1) %sf unordered, align 4
  br label %cont
acc:
  %psf = getelementptr inbounds i8, ptr addrspace(1) %px, i64 8
  %pv = load atomic i32, ptr addrspace(1) %psf unordered, align 4
  %nv = add i32 %pv, 1
  store atomic i32 %nv, ptr addrspace(1) %sf unordered, align 4
  br label %cont
cont:
  br label %latch
latch:
  %i1 = add i32 %i, 1
  br label %hdr
exit:
  %ec = icmp eq ptr addrspace(1) %px, null
  br i1 %ec, label %done, label %observe
observe:
  %osf = getelementptr inbounds i8, ptr addrspace(1) %px, i64 8
  %lastf = load atomic i32, ptr addrspace(1) %osf unordered, align 4
  call void @use(i32 %lastf)
  br label %done
done:
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; No poison leaks to the exit use, and the carried alloc survives (it is NOT
; eliminated). Both paths (no-preheader single-pass and fixpoint) must agree.
; NOPRE: define void @test_142_loopcarried_local
; NOPRE: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; NOPRE: call void @use(i32 %lastf)
; NOPRE-NOT: poison
; FIXPOINT: define void @test_142_loopcarried_local
; FIXPOINT: invoke hotspotcc ptr addrspace(1) @jeandle.new_instance
; FIXPOINT: call void @use(i32 %lastf)
; FIXPOINT-NOT: poison

!java-method-compilation = !{}
