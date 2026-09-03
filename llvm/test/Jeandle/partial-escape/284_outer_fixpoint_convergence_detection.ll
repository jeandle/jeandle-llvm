; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=4 \
; RUN:   -jeandle-dump-pea-ir-function=test_convergence_detection %s 2>&1 \
; RUN:   | grep '^;; PEA-' | FileCheck %s --check-prefix=HIGH
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_convergence_detection %s 2>&1 \
; RUN:   | grep '^;; PEA-' | FileCheck %s --check-prefix=HIGH
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=4 \
; RUN:   %s -o %t.cap4.ll
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=16 \
; RUN:   %s -o %t.cap16.ll
; RUN: diff %t.cap4.ll %t.cap16.ll
; RUN: FileCheck %s --check-prefix=FINAL < %t.cap4.ll
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_convergence_detection %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=REPEAT
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=16 %s -o %t.repeat.ll
; RUN: diff %t.cap16.ll %t.repeat.ll
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_partial_replay_converges %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=PARTIAL
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_partial_replay_converges %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=PARTIAL-REPEAT
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_lock_replay_converges %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=LOCK
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_merged_lock_replay_converges %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=MERGED-LOCK
; RUN: opt -S -passes="partial-escape-iterative" -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_per_pred_cascade_replay_converges %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=PER-PRED-CASCADE
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_merged_lock_replay_converges %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=MERGED-LOCK-REPEAT
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -verify-each -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_volatile_replay_mismatch %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=VOLATILE-REPEAT
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -verify-each -jeandle-pea-iterations=16 \
; RUN:   -jeandle-dump-pea-ir-function=test_syncscope_replay_mismatch %s 2>&1 \
; RUN:   | grep '^;; PEA-DUMP' | FileCheck %s --check-prefix=SYNCSCOPE-REPEAT
; RUN: opt -S -passes="partial-escape-iterative,partial-escape-iterative" \
; RUN:   -verify-each -jeandle-pea-iterations=16 %s -o %t.repeat.ll
; RUN: not grep '!jeandle[.]pea[.]replay' %t.repeat.ll
; RUN: FileCheck %s --check-prefixes=PARTIAL-FINAL,LOCK-FINAL,MERGED-LOCK-FINAL,VALUE-FINAL,VOLATILE-FINAL,SYNCSCOPE-FINAL,DEAD-FINAL \
; RUN:   < %t.repeat.ll
; RUN: sed -n '/^define i32 @test_partial_replay_converges/,/^}/p' %t.repeat.ll \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=PARTIAL-STORE-COUNT
; RUN: sed -n '/^define i32 @test_replay_value_change/,/^}/p' %t.repeat.ll \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=VALUE-STORE-COUNT
; RUN: sed -n '/^define i32 @test_volatile_replay_mismatch/,/^}/p' %t.repeat.ll \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=VOLATILE-STORE-COUNT
; RUN: sed -n '/^define i32 @test_volatile_replay_mismatch/,/^}/p' %t.repeat.ll \
; RUN:   | grep -c '^  store atomic volatile' | FileCheck %s --check-prefix=VOLATILE-ACCESS-COUNT
; RUN: sed -n '/^define i32 @test_syncscope_replay_mismatch/,/^}/p' %t.repeat.ll \
; RUN:   | grep -c '^  store atomic' | FileCheck %s --check-prefix=SYNCSCOPE-STORE-COUNT
; RUN: sed -n '/^define void @test_merged_lock_replay_converges/,/^}/p' %t.repeat.ll \
; RUN:   | grep -c 'call hotspotcc void @jeandle.monitorenter_with_lightweight_lock' \
; RUN:   | FileCheck %s --check-prefix=MERGED-LOCK-COUNT

; Outer-fixpoint convergence detection. The first transform is idle, but its
; following canonicalization deletes the constant-false escape branch. The
; second transform eliminates the now non-escaping allocation. The next idle
; transform and its unchanged current canonicalization establish the real IR
; fixpoint.
;
; Caps 4 and 16 therefore stop at exactly the same stable point and produce
; byte-identical IR. Running the pipeline twice resets the iteration counter,
; proving that the pass manager executes both instances; every transform in
; the second instance is idle and its final IR is unchanged.

@G_zero = private unnamed_addr constant i32 0

declare hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr, i32, i1)
declare hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1), ptr) nounwind
declare void @sink(ptr addrspace(1))
declare i32 @__gxx_personality_v0(...)

define i32 @test_convergence_detection()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 12345 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %v = load i32, ptr @G_zero, align 4
  %c = icmp ne i32 %v, 0
  br i1 %c, label %escape, label %fast
escape:
  call void @sink(ptr addrspace(1) %o)
  br label %fast
fast:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 42, ptr addrspace(1) %slot unordered, align 4
  %val = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %val
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define i32 @test_partial_replay_converges(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 23456 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  %slot2 = getelementptr inbounds i8, ptr addrspace(1) %o, i64 12
  store atomic i32 99, ptr addrspace(1) %slot2 unordered, align 4
  br i1 %escape, label %escape.block, label %merge
escape.block:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
merge:
  %loaded = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  %loaded2 = load atomic i32, ptr addrspace(1) %slot2 unordered, align 4
  %sum = add i32 %loaded, %loaded2
  ret i32 %sum
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

define void @test_lock_replay_converges(i1 %escape)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %lock = alloca i64, align 8
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 34567 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  br i1 %escape, label %escape.block, label %merge
escape.block:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
merge:
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %o, ptr %lock)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; Escaping B while the held lock stack is [A@0, B@1, A@2] cascades A at the
; same escape point. The two Materialize effects therefore use the merged-lock
; table: the tail emits A@0, B@1, A@2 once in global depth order. Per-effect
; emission would incorrectly group A's two locks as A@0, A@2, B@1.
define void @test_merged_lock_replay_converges()
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la0 = alloca i64, align 8
  %lb1 = alloca i64, align 8
  %la2 = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40101 to ptr), i32 16, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40102 to ptr), i32 16, i1 false)
       to label %nb unwind label %u
nb:
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la2)
  call void @sink(ptr addrspace(1) %b)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la0)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A selected object escapes from either predecessor while A@0, B@1, A@2 are
; held.  Escaping C cascades A and B through the live lock stack; escaping B
; recursively materializes A through b.next.  The complete field-and-lock
; replay at each physical predecessor must have one stable structural order,
; independent of recursive materialization discovery order in a later round.
define void @test_per_pred_cascade_replay_converges(i1 %left)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %la0 = alloca i64, align 8
  %lb1 = alloca i64, align 8
  %la2 = alloca i64, align 8
  %lr3 = alloca i64, align 8
  %a = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40201 to ptr), i32 24, i1 false)
       to label %na unwind label %u
na:
  %b = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40202 to ptr), i32 24, i1 false)
       to label %nb unwind label %u
nb:
  %c = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 40203 to ptr), i32 24, i1 false)
       to label %nc unwind label %u
nc:
  %a.id = getelementptr inbounds i8, ptr addrspace(1) %a, i64 8
  store atomic i32 1, ptr addrspace(1) %a.id unordered, align 4
  %a.x = getelementptr inbounds i8, ptr addrspace(1) %a, i64 12
  store atomic i32 10, ptr addrspace(1) %a.x unordered, align 4
  %b.id = getelementptr inbounds i8, ptr addrspace(1) %b, i64 8
  store atomic i32 2, ptr addrspace(1) %b.id unordered, align 4
  %b.x = getelementptr inbounds i8, ptr addrspace(1) %b, i64 12
  store atomic i32 20, ptr addrspace(1) %b.x unordered, align 4
  %b.next = getelementptr inbounds i8, ptr addrspace(1) %b, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %b.next unordered, align 8
  %c.id = getelementptr inbounds i8, ptr addrspace(1) %c, i64 8
  store atomic i32 3, ptr addrspace(1) %c.id unordered, align 4
  %c.x = getelementptr inbounds i8, ptr addrspace(1) %c, i64 12
  store atomic i32 30, ptr addrspace(1) %c.x unordered, align 4
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la0)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb1)
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la2)
  br i1 %left, label %left.pred, label %right.pred
left.pred:
  store atomic i32 21, ptr addrspace(1) %b.x unordered, align 4
  br label %consume
right.pred:
  store atomic i32 31, ptr addrspace(1) %c.x unordered, align 4
  br label %consume
consume:
  %r = phi ptr addrspace(1) [ %b, %left.pred ], [ %c, %right.pred ]
  call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(
      ptr addrspace(1) %r, ptr %lr3)
  call void @sink(ptr addrspace(1) %r)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %r, ptr %lr3)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la2)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %b, ptr %lb1)
  call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(
      ptr addrspace(1) %a, ptr %la0)
  ret void
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A new source store after a preceding exact replay invalidates that replay.
; The next transform must remove both source stores and emit exactly the current
; value once; a stale replay must not be retained.
define i32 @test_replay_value_change(i1 %escape, i32 %old, i32 %current)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 45678 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %old.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %old, ptr addrspace(1) %old.slot unordered, align 4
  %current.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %current, ptr addrspace(1) %current.slot unordered, align 4
  br i1 %escape, label %escape.block, label %merge
escape.block:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
merge:
  %loaded = load atomic i32, ptr addrspace(1) %current.slot unordered, align 4
  ret i32 %loaded
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A volatile source store cannot be reused as an ordinary materialization
; replay. The tracked value is replayed before the volatile access materializes
; the receiver, while the original volatile access itself remains observable.
define i32 @test_volatile_replay_mismatch(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 50101 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  br i1 %escape, label %escape.block, label %merge
escape.block:
  %replay.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic volatile i32 %value, ptr addrspace(1) %replay.slot unordered,
      align 4
  call void @sink(ptr addrspace(1) %o)
  br label %merge
merge:
  %loaded = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %loaded
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; A non-system sync scope likewise changes the operation. It must not satisfy
; the exact replay matcher even when its value, receiver, offset, ordering, and
; alignment match the materialization plan.
define i32 @test_syncscope_replay_mismatch(i1 %escape, i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 50102 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  br i1 %escape, label %escape.block, label %merge
escape.block:
  %replay.slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %replay.slot syncscope("singlethread")
      unordered, align 4
  call void @sink(ptr addrspace(1) %o)
  br label %merge
merge:
  %loaded = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %loaded
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; The first transform can create a replay in the apparently escaping arm. Once
; canonicalization deletes that arm, the next transform must eliminate both the
; allocation and its dead replay rather than treating structural similarity as
; liveness.
define i32 @test_dead_replay_branch(i32 %value)
    gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %o = invoke hotspotcc ptr addrspace(1) @jeandle.new_instance(
            ptr inttoptr (i64 56789 to ptr), i32 16, i1 false)
       to label %n unwind label %u
n:
  %slot = getelementptr inbounds i8, ptr addrspace(1) %o, i64 8
  store atomic i32 %value, ptr addrspace(1) %slot unordered, align 4
  %zero = load i32, ptr @G_zero, align 4
  %escapes = icmp ne i32 %zero, 0
  br i1 %escapes, label %escape.block, label %merge
escape.block:
  call void @sink(ptr addrspace(1) %o)
  br label %merge
merge:
  %loaded = load atomic i32, ptr addrspace(1) %slot unordered, align 4
  ret i32 %loaded
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

; HIGH: ;; PEA-DUMP before iter=0 function test_convergence_detection
; HIGH-NEXT: ;; PEA-DUMP after iter=0 function test_convergence_detection transform_idle=1
; HIGH-NEXT: ;; PEA-DUMP before iter=1 function test_convergence_detection
; HIGH-NEXT: ;; PEA-DUMP after iter=1 function test_convergence_detection transform_idle=0
; HIGH-NEXT: ;; PEA-DUMP before iter=2 function test_convergence_detection
; HIGH-NEXT: ;; PEA-DUMP after iter=2 function test_convergence_detection transform_idle=1
; HIGH-NEXT: ;; PEA-SUMMARY function test_convergence_detection rounds=3 stop=fixpoint
; HIGH-NOT: ;; PEA-

; REPEAT: ;; PEA-DUMP before iter=0 function test_convergence_detection
; REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_convergence_detection transform_idle=1
; REPEAT-NEXT: ;; PEA-DUMP before iter=1 function test_convergence_detection
; REPEAT-NEXT: ;; PEA-DUMP after iter=1 function test_convergence_detection transform_idle=0
; REPEAT-NEXT: ;; PEA-DUMP before iter=2 function test_convergence_detection
; REPEAT-NEXT: ;; PEA-DUMP after iter=2 function test_convergence_detection transform_idle=1
; REPEAT-NEXT: ;; PEA-DUMP before iter=0 function test_convergence_detection
; REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_convergence_detection transform_idle=1
; REPEAT-NOT: ;; PEA-DUMP

; A stable partial escape keeps its original allocation and one replay at each
; materialization point. Once those replays already match the next analysis,
; later transforms are idle rather than deleting and recreating equivalent
; stores. The second pipeline invocation is therefore entirely idle.
; PARTIAL: ;; PEA-DUMP before iter=0 function test_partial_replay_converges
; PARTIAL-NEXT: ;; PEA-DUMP after iter=0 function test_partial_replay_converges transform_idle=0
; PARTIAL-NEXT: ;; PEA-DUMP before iter=1 function test_partial_replay_converges
; PARTIAL-NEXT: ;; PEA-DUMP after iter=1 function test_partial_replay_converges transform_idle=1
; PARTIAL-NOT: ;; PEA-DUMP

; PARTIAL-REPEAT: ;; PEA-DUMP before iter=0 function test_partial_replay_converges
; PARTIAL-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_partial_replay_converges transform_idle=0
; PARTIAL-REPEAT-NEXT: ;; PEA-DUMP before iter=1 function test_partial_replay_converges
; PARTIAL-REPEAT-NEXT: ;; PEA-DUMP after iter=1 function test_partial_replay_converges transform_idle=1
; PARTIAL-REPEAT-NEXT: ;; PEA-DUMP before iter=0 function test_partial_replay_converges
; PARTIAL-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_partial_replay_converges transform_idle=1
; PARTIAL-REPEAT-NOT: ;; PEA-DUMP

; The replayed monitorenter is stable for the same reason as field stores. It
; must remain a single bare hotspotcc call on the original allocation; neither
; outer retries nor a second pipeline invocation may duplicate the held lock.
; LOCK: ;; PEA-DUMP before iter=0 function test_lock_replay_converges
; LOCK-NEXT: ;; PEA-DUMP after iter=0 function test_lock_replay_converges transform_idle=0
; LOCK-NEXT: ;; PEA-DUMP before iter=1 function test_lock_replay_converges
; LOCK-NEXT: ;; PEA-DUMP after iter=1 function test_lock_replay_converges transform_idle=1
; LOCK-NOT: ;; PEA-DUMP

; The input's complete a@0,b@1,a@2 suffix already has the exact replay shape,
; so structural matching reuses it without a delete-and-recreate first round.
; MERGED-LOCK: ;; PEA-DUMP before iter=0 function test_merged_lock_replay_converges
; MERGED-LOCK-NEXT: ;; PEA-DUMP after iter=0 function test_merged_lock_replay_converges transform_idle=1
; MERGED-LOCK-NEXT: ;; PEA-DUMP before iter=1 function test_merged_lock_replay_converges
; MERGED-LOCK-NEXT: ;; PEA-DUMP after iter=1 function test_merged_lock_replay_converges transform_idle=1
; MERGED-LOCK-NOT: ;; PEA-DUMP

; PER-PRED-CASCADE: ;; PEA-DUMP before iter=0 function test_per_pred_cascade_replay_converges
; PER-PRED-CASCADE-NEXT: ;; PEA-DUMP after iter=0 function test_per_pred_cascade_replay_converges transform_idle=0
; PER-PRED-CASCADE-NEXT: ;; PEA-DUMP before iter=1 function test_per_pred_cascade_replay_converges
; PER-PRED-CASCADE-NEXT: ;; PEA-DUMP after iter=1 function test_per_pred_cascade_replay_converges transform_idle=1
; PER-PRED-CASCADE-NOT: ;; PEA-DUMP

; MERGED-LOCK-REPEAT: ;; PEA-DUMP before iter=0 function test_merged_lock_replay_converges
; MERGED-LOCK-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_merged_lock_replay_converges transform_idle=1
; MERGED-LOCK-REPEAT-NEXT: ;; PEA-DUMP before iter=1 function test_merged_lock_replay_converges
; MERGED-LOCK-REPEAT-NEXT: ;; PEA-DUMP after iter=1 function test_merged_lock_replay_converges transform_idle=1
; MERGED-LOCK-REPEAT-NEXT: ;; PEA-DUMP before iter=0 function test_merged_lock_replay_converges
; MERGED-LOCK-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_merged_lock_replay_converges transform_idle=1
; MERGED-LOCK-REPEAT-NOT: ;; PEA-DUMP

; The volatile access is preserved while its preceding ordinary replay reaches
; a stable shape. A second pipeline invocation is entirely idle.
; VOLATILE-REPEAT: ;; PEA-DUMP before iter=0 function test_volatile_replay_mismatch
; VOLATILE-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_volatile_replay_mismatch transform_idle=0
; VOLATILE-REPEAT-NEXT: ;; PEA-DUMP before iter=1 function test_volatile_replay_mismatch
; VOLATILE-REPEAT-NEXT: ;; PEA-DUMP after iter=1 function test_volatile_replay_mismatch transform_idle=1
; VOLATILE-REPEAT-NEXT: ;; PEA-DUMP before iter=0 function test_volatile_replay_mismatch
; VOLATILE-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_volatile_replay_mismatch transform_idle=1
; VOLATILE-REPEAT-NOT: ;; PEA-DUMP

; SYNCSCOPE-REPEAT: ;; PEA-DUMP before iter=0 function test_syncscope_replay_mismatch
; SYNCSCOPE-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_syncscope_replay_mismatch transform_idle=0
; SYNCSCOPE-REPEAT-NEXT: ;; PEA-DUMP before iter=1 function test_syncscope_replay_mismatch
; SYNCSCOPE-REPEAT-NEXT: ;; PEA-DUMP after iter=1 function test_syncscope_replay_mismatch transform_idle=1
; SYNCSCOPE-REPEAT-NEXT: ;; PEA-DUMP before iter=0 function test_syncscope_replay_mismatch
; SYNCSCOPE-REPEAT-NEXT: ;; PEA-DUMP after iter=0 function test_syncscope_replay_mismatch transform_idle=1
; SYNCSCOPE-REPEAT-NOT: ;; PEA-DUMP

; FINAL-LABEL: define i32 @test_convergence_detection()
; FINAL-NOT: jeandle.new_instance
; FINAL-NOT: call void @sink
; FINAL-NOT: store
; FINAL-NOT: load
; FINAL-NOT: phi
; FINAL-NOT: poison
; FINAL-NEXT: entry:
; FINAL-NEXT: ret i32 42
; FINAL-NEXT: }

; PARTIAL-FINAL-LABEL: define i32 @test_partial_replay_converges(
; PARTIAL-FINAL: %[[PARTIAL_O:[A-Za-z0-9._]+]] = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; PARTIAL-FINAL: br i1 %escape, label %escape.block, label %[[PARTIAL_EDGE:[-A-Za-z$._0-9]+]]
; PARTIAL-FINAL: escape.block:
; PARTIAL-FINAL: store atomic i32 %value,
; PARTIAL-FINAL: store atomic i32 99,
; PARTIAL-FINAL-NEXT: call void @sink(ptr addrspace(1) %[[PARTIAL_O]])
; PARTIAL-FINAL: [[PARTIAL_EDGE]]:
; PARTIAL-FINAL: store atomic i32 %value,
; PARTIAL-FINAL: store atomic i32 99,
; PARTIAL-FINAL-NEXT: br label %merge
; PARTIAL-FINAL: merge:
; PARTIAL-FINAL-NOT: store atomic
; PARTIAL-FINAL-NOT: poison
; PARTIAL-FINAL: }
; PARTIAL-STORE-COUNT: {{^4$}}

; LOCK-FINAL-LABEL: define void @test_lock_replay_converges(
; LOCK-FINAL: %[[LOCK_O:[A-Za-z0-9._]+]] = call hotspotcc ptr addrspace(1) @jeandle.new_instance
; LOCK-FINAL: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[LOCK_O]], ptr nonnull %lock)
; LOCK-FINAL-NOT: jeandle.monitorenter_with_lightweight_lock
; LOCK-FINAL: call void @sink(ptr addrspace(1) %[[LOCK_O]])
; LOCK-FINAL: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[LOCK_O]], ptr nonnull %lock)
; LOCK-FINAL-NOT: jeandle.monitorenter_with_lightweight_lock
; LOCK-FINAL-NOT: jeandle.monitorexit_with_lightweight_lock
; LOCK-FINAL: }

; MERGED-LOCK-FINAL-LABEL: define void @test_merged_lock_replay_converges()
; MERGED-LOCK-FINAL: %[[MERGED_A:[A-Za-z0-9._]+]] = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr nonnull inttoptr (i64 40101 to ptr), i32 16, i1 false)
; MERGED-LOCK-FINAL: %[[MERGED_B:[A-Za-z0-9._]+]] = call hotspotcc ptr addrspace(1) @jeandle.new_instance(ptr nonnull inttoptr (i64 40102 to ptr), i32 16, i1 false)
; MERGED-LOCK-FINAL: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MERGED_A]], ptr nonnull %la0)
; MERGED-LOCK-FINAL-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MERGED_B]], ptr nonnull %lb1)
; MERGED-LOCK-FINAL-NEXT: call hotspotcc void @jeandle.monitorenter_with_lightweight_lock(ptr addrspace(1) %[[MERGED_A]], ptr nonnull %la2)
; MERGED-LOCK-FINAL-NEXT: call void @sink(ptr addrspace(1) %[[MERGED_B]])
; MERGED-LOCK-FINAL: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MERGED_A]], ptr nonnull %la2)
; MERGED-LOCK-FINAL-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MERGED_B]], ptr nonnull %lb1)
; MERGED-LOCK-FINAL-NEXT: call hotspotcc void @jeandle.monitorexit_with_lightweight_lock(ptr addrspace(1) %[[MERGED_A]], ptr nonnull %la0)
; MERGED-LOCK-FINAL-NOT: jeandle.monitorenter_with_lightweight_lock
; MERGED-LOCK-FINAL-NOT: jeandle.monitorexit_with_lightweight_lock
; MERGED-LOCK-FINAL: }
; MERGED-LOCK-COUNT: {{^3$}}

; VALUE-FINAL-LABEL: define i32 @test_replay_value_change(
; VALUE-FINAL-NOT: store atomic i32 %old
; VALUE-FINAL: store atomic i32 %current,
; VALUE-FINAL-NOT: store atomic i32 %old
; VALUE-FINAL: store atomic i32 %current,
; VALUE-FINAL-NOT: store atomic i32 %old
; VALUE-FINAL-NOT: poison
; VALUE-FINAL: }
; VALUE-STORE-COUNT: {{^2$}}

; VOLATILE-FINAL-LABEL: define i32 @test_volatile_replay_mismatch(
; VOLATILE-FINAL-NOT: syncscope
; VOLATILE-FINAL: escape.block:
; VOLATILE-FINAL-NEXT: %[[VOLATILE_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) {{.*}}, i64 8
; VOLATILE-FINAL-NEXT: %[[VOLATILE_REPLAY:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) {{.*}}, i64 8
; VOLATILE-FINAL-NEXT: store atomic i32 %value, ptr addrspace(1) %[[VOLATILE_REPLAY]] unordered, align 4
; VOLATILE-FINAL-NEXT: store atomic volatile i32 %value, ptr addrspace(1) %[[VOLATILE_SLOT]] unordered, align 4
; VOLATILE-FINAL-NEXT: call void @sink
; VOLATILE-FINAL-NOT: store atomic volatile
; VOLATILE-FINAL-NOT: syncscope
; VOLATILE-FINAL: }
; VOLATILE-STORE-COUNT: {{^3$}}
; VOLATILE-ACCESS-COUNT: {{^1$}}

; SYNCSCOPE-FINAL-LABEL: define i32 @test_syncscope_replay_mismatch(
; SYNCSCOPE-FINAL-NOT: volatile
; SYNCSCOPE-FINAL-NOT: syncscope
; SYNCSCOPE-FINAL: escape.block:
; SYNCSCOPE-FINAL-NEXT: %[[SYNCSCOPE_SLOT:[A-Za-z0-9._]+]] = getelementptr inbounds{{( nuw)?}} i8, ptr addrspace(1) {{.*}}, i64 8
; SYNCSCOPE-FINAL-NEXT: store atomic i32 %value, ptr addrspace(1) %[[SYNCSCOPE_SLOT]] unordered, align 4
; SYNCSCOPE-FINAL-NEXT: call void @sink
; SYNCSCOPE-FINAL-NOT: volatile
; SYNCSCOPE-FINAL-NOT: syncscope
; SYNCSCOPE-FINAL: }
; SYNCSCOPE-STORE-COUNT: {{^2$}}

; DEAD-FINAL-LABEL: define i32 @test_dead_replay_branch(i32 %value)
; DEAD-FINAL-NOT: jeandle.new_instance
; DEAD-FINAL-NOT: @sink
; DEAD-FINAL-NOT: store
; DEAD-FINAL-NOT: load
; DEAD-FINAL-NEXT: entry:
; DEAD-FINAL-NEXT: ret i32 %value
; DEAD-FINAL-NEXT: }

!java-method-compilation = !{}
