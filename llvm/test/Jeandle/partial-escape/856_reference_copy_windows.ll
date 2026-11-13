; RUN: opt -S -verify-each -passes="require<partial-escape-analysis>,partial-escape-transform,instcombine" -jeandle-vm-callback-log=%S/Inputs/856_reference_copy_windows.cblog %s | FileCheck %s

target datalayout = "e-p:64:64-p3:32:32"
@VMOptions.UseCompressedOops = constant i1 false
@arrayOopDesc.element_size.object = constant i32 8
declare hotspotcc ptr addrspace(1) @jeandle.new_array(ptr, i32, i32, i32, i32, i1, i1)
declare void @jeandle.copy(ptr addrspace(1), i64, ptr addrspace(1), i64, i64, ptr, ptr, i64, i64)
declare i32 @__gxx_personality_v0(...)

; CHECK-LABEL: define ptr addrspace(1) @reverse(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: store atomic
; CHECK: ret ptr addrspace(1) %b
define ptr addrspace(1) @reverse(ptr addrspace(1) %a, ptr addrspace(1) %b, ptr addrspace(1) %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 1000 to ptr), i32 3, i32 40, i32 16, i32 1048576, i1 false, i1 false) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p0 unordered, align 8
  %p1 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 24
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %p1 unordered, align 8
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 32
  store atomic ptr addrspace(1) %c, ptr addrspace(1) %p2 unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %array, i64 0, ptr addrspace(1) %array, i64 1, i64 2, ptr null, ptr null, i64 3, i64 3) #0 to label %read unwind label %u
read:
  %rp = getelementptr inbounds i8, ptr addrspace(1) %array, i64 32
  %result = load atomic ptr addrspace(1), ptr addrspace(1) %rp unordered, align 8
  ret ptr addrspace(1) %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}


; CHECK-LABEL: define ptr addrspace(1) @forward(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: store atomic
; CHECK: ret ptr addrspace(1) %c
define ptr addrspace(1) @forward(ptr addrspace(1) %a, ptr addrspace(1) %b, ptr addrspace(1) %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 1000 to ptr), i32 3, i32 40, i32 16, i32 1048576, i1 false, i1 false) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p0 unordered, align 8
  %p1 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 24
  store atomic ptr addrspace(1) %b, ptr addrspace(1) %p1 unordered, align 8
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 32
  store atomic ptr addrspace(1) %c, ptr addrspace(1) %p2 unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %array, i64 1, ptr addrspace(1) %array, i64 0, i64 2, ptr null, ptr null, i64 3, i64 3) #0 to label %read unwind label %u
read:
  %rp = getelementptr inbounds i8, ptr addrspace(1) %array, i64 24
  %result = load atomic ptr addrspace(1), ptr addrspace(1) %rp unordered, align 8
  ret ptr addrspace(1) %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}


; CHECK-LABEL: define ptr addrspace(1) @sparse_default(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: store atomic
; CHECK: ret ptr addrspace(1) null
define ptr addrspace(1) @sparse_default(ptr addrspace(1) %a, ptr addrspace(1) %b, ptr addrspace(1) %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 1000 to ptr), i32 3, i32 40, i32 16, i32 1048576, i1 false, i1 false) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p0 unordered, align 8
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 32
  store atomic ptr addrspace(1) %c, ptr addrspace(1) %p2 unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %array, i64 0, ptr addrspace(1) %array, i64 1, i64 2, ptr null, ptr null, i64 3, i64 3) #0 to label %read unwind label %u
read:
  %rp = getelementptr inbounds i8, ptr addrspace(1) %array, i64 32
  %result = load atomic ptr addrspace(1), ptr addrspace(1) %rp unordered, align 8
  ret ptr addrspace(1) %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}


; CHECK-LABEL: define ptr addrspace(1) @large(
; CHECK-NOT: @jeandle.new_array
; CHECK-NOT: @jeandle.copy
; CHECK-NOT: store atomic
; CHECK: ret ptr addrspace(1) %a
define ptr addrspace(1) @large(ptr addrspace(1) %a, ptr addrspace(1) %b, ptr addrspace(1) %c) gc "hotspotgc" personality ptr @__gxx_personality_v0 {
entry:
  %array = invoke hotspotcc ptr addrspace(1) @jeandle.new_array(ptr inttoptr (i64 1000 to ptr), i32 128, i32 1040, i32 16, i32 1048576, i1 false, i1 false) to label %init unwind label %u
init:
  %p0 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 16
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p0 unordered, align 8
  %p1 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 24
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p1 unordered, align 8
  %p2 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 32
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p2 unordered, align 8
  %p3 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 40
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p3 unordered, align 8
  %p4 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 48
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p4 unordered, align 8
  %p5 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 56
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p5 unordered, align 8
  %p6 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 64
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p6 unordered, align 8
  %p7 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 72
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p7 unordered, align 8
  %p8 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 80
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p8 unordered, align 8
  %p9 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 88
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p9 unordered, align 8
  %p10 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 96
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p10 unordered, align 8
  %p11 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 104
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p11 unordered, align 8
  %p12 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 112
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p12 unordered, align 8
  %p13 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 120
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p13 unordered, align 8
  %p14 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 128
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p14 unordered, align 8
  %p15 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 136
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p15 unordered, align 8
  %p16 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 144
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p16 unordered, align 8
  %p17 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 152
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p17 unordered, align 8
  %p18 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 160
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p18 unordered, align 8
  %p19 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 168
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p19 unordered, align 8
  %p20 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 176
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p20 unordered, align 8
  %p21 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 184
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p21 unordered, align 8
  %p22 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 192
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p22 unordered, align 8
  %p23 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 200
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p23 unordered, align 8
  %p24 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 208
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p24 unordered, align 8
  %p25 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 216
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p25 unordered, align 8
  %p26 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 224
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p26 unordered, align 8
  %p27 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 232
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p27 unordered, align 8
  %p28 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 240
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p28 unordered, align 8
  %p29 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 248
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p29 unordered, align 8
  %p30 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 256
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p30 unordered, align 8
  %p31 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 264
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p31 unordered, align 8
  %p32 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 272
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p32 unordered, align 8
  %p33 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 280
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p33 unordered, align 8
  %p34 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 288
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p34 unordered, align 8
  %p35 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 296
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p35 unordered, align 8
  %p36 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 304
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p36 unordered, align 8
  %p37 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 312
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p37 unordered, align 8
  %p38 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 320
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p38 unordered, align 8
  %p39 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 328
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p39 unordered, align 8
  %p40 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 336
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p40 unordered, align 8
  %p41 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 344
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p41 unordered, align 8
  %p42 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 352
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p42 unordered, align 8
  %p43 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 360
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p43 unordered, align 8
  %p44 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 368
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p44 unordered, align 8
  %p45 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 376
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p45 unordered, align 8
  %p46 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 384
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p46 unordered, align 8
  %p47 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 392
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p47 unordered, align 8
  %p48 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 400
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p48 unordered, align 8
  %p49 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 408
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p49 unordered, align 8
  %p50 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 416
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p50 unordered, align 8
  %p51 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 424
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p51 unordered, align 8
  %p52 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 432
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p52 unordered, align 8
  %p53 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 440
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p53 unordered, align 8
  %p54 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 448
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p54 unordered, align 8
  %p55 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 456
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p55 unordered, align 8
  %p56 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 464
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p56 unordered, align 8
  %p57 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 472
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p57 unordered, align 8
  %p58 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 480
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p58 unordered, align 8
  %p59 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 488
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p59 unordered, align 8
  %p60 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 496
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p60 unordered, align 8
  %p61 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 504
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p61 unordered, align 8
  %p62 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 512
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p62 unordered, align 8
  %p63 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 520
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p63 unordered, align 8
  %p64 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 528
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p64 unordered, align 8
  %p65 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 536
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p65 unordered, align 8
  %p66 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 544
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p66 unordered, align 8
  %p67 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 552
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p67 unordered, align 8
  %p68 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 560
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p68 unordered, align 8
  %p69 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 568
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p69 unordered, align 8
  %p70 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 576
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p70 unordered, align 8
  %p71 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 584
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p71 unordered, align 8
  %p72 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 592
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p72 unordered, align 8
  %p73 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 600
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p73 unordered, align 8
  %p74 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 608
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p74 unordered, align 8
  %p75 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 616
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p75 unordered, align 8
  %p76 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 624
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p76 unordered, align 8
  %p77 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 632
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p77 unordered, align 8
  %p78 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 640
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p78 unordered, align 8
  %p79 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 648
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p79 unordered, align 8
  %p80 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 656
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p80 unordered, align 8
  %p81 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 664
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p81 unordered, align 8
  %p82 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 672
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p82 unordered, align 8
  %p83 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 680
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p83 unordered, align 8
  %p84 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 688
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p84 unordered, align 8
  %p85 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 696
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p85 unordered, align 8
  %p86 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 704
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p86 unordered, align 8
  %p87 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 712
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p87 unordered, align 8
  %p88 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 720
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p88 unordered, align 8
  %p89 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 728
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p89 unordered, align 8
  %p90 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 736
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p90 unordered, align 8
  %p91 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 744
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p91 unordered, align 8
  %p92 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 752
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p92 unordered, align 8
  %p93 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 760
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p93 unordered, align 8
  %p94 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 768
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p94 unordered, align 8
  %p95 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 776
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p95 unordered, align 8
  %p96 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 784
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p96 unordered, align 8
  %p97 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 792
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p97 unordered, align 8
  %p98 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 800
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p98 unordered, align 8
  %p99 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 808
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p99 unordered, align 8
  %p100 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 816
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p100 unordered, align 8
  %p101 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 824
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p101 unordered, align 8
  %p102 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 832
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p102 unordered, align 8
  %p103 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 840
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p103 unordered, align 8
  %p104 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 848
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p104 unordered, align 8
  %p105 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 856
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p105 unordered, align 8
  %p106 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 864
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p106 unordered, align 8
  %p107 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 872
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p107 unordered, align 8
  %p108 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 880
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p108 unordered, align 8
  %p109 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 888
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p109 unordered, align 8
  %p110 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 896
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p110 unordered, align 8
  %p111 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 904
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p111 unordered, align 8
  %p112 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 912
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p112 unordered, align 8
  %p113 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 920
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p113 unordered, align 8
  %p114 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 928
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p114 unordered, align 8
  %p115 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 936
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p115 unordered, align 8
  %p116 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 944
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p116 unordered, align 8
  %p117 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 952
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p117 unordered, align 8
  %p118 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 960
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p118 unordered, align 8
  %p119 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 968
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p119 unordered, align 8
  %p120 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 976
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p120 unordered, align 8
  %p121 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 984
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p121 unordered, align 8
  %p122 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 992
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p122 unordered, align 8
  %p123 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 1000
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p123 unordered, align 8
  %p124 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 1008
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p124 unordered, align 8
  %p125 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 1016
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p125 unordered, align 8
  %p126 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 1024
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p126 unordered, align 8
  %p127 = getelementptr inbounds i8, ptr addrspace(1) %array, i64 1032
  store atomic ptr addrspace(1) %a, ptr addrspace(1) %p127 unordered, align 8
  invoke void @jeandle.copy(ptr addrspace(1) %array, i64 0, ptr addrspace(1) %array, i64 1, i64 127, ptr null, ptr null, i64 128, i64 128) #0 to label %read unwind label %u
read:
  %rp = getelementptr inbounds i8, ptr addrspace(1) %array, i64 1032
  %result = load atomic ptr addrspace(1), ptr addrspace(1) %rp unordered, align 8
  ret ptr addrspace(1) %result
u:
  %lp = landingpad i64 cleanup
  resume i64 %lp
}

attributes #0 = { "jeandle.copy.kind"="arraycopy" }
!java-method-compilation = !{}
