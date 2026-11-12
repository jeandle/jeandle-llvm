; ModuleID = 'context-reuse'
source_filename = "context-reuse"

define void @test(ptr %obj, i32 %0) {
entry:
  br label %guard

guard:                                            ; preds = %entry
  %check = call i1 @jeandle.check_instanceof(ptr inttoptr (i64 22 to ptr), ptr %obj)
  br i1 %check, label %path0, label %fail

fail:                                             ; preds = %guard
  %other.noise = add i32 %0, 1
  ret void

path0:                                            ; preds = %guard
  br label %path1

path1:                                            ; preds = %path0
  br label %path2

path2:                                            ; preds = %path1
  br label %path3

path3:                                            ; preds = %path2
  br label %path4

path4:                                            ; preds = %path3
  br label %path5

path5:                                            ; preds = %path4
  br label %path6

path6:                                            ; preds = %path5
  br label %path7

path7:                                            ; preds = %path6
  br label %path8

path8:                                            ; preds = %path7
  br label %path9

path9:                                            ; preds = %path8
  br label %path10

path10:                                           ; preds = %path9
  br label %path11

path11:                                           ; preds = %path10
  br label %path12

path12:                                           ; preds = %path11
  br label %path13

path13:                                           ; preds = %path12
  br label %path14

path14:                                           ; preds = %path13
  br label %path15

path15:                                           ; preds = %path14
  br label %path16

path16:                                           ; preds = %path15
  br label %path17

path17:                                           ; preds = %path16
  br label %path18

path18:                                           ; preds = %path17
  br label %path19

path19:                                           ; preds = %path18
  br label %path20

path20:                                           ; preds = %path19
  br label %path21

path21:                                           ; preds = %path20
  br label %path22

path22:                                           ; preds = %path21
  br label %path23

path23:                                           ; preds = %path22
  br label %path24

path24:                                           ; preds = %path23
  br label %path25

path25:                                           ; preds = %path24
  br label %path26

path26:                                           ; preds = %path25
  br label %path27

path27:                                           ; preds = %path26
  br label %path28

path28:                                           ; preds = %path27
  br label %path29

path29:                                           ; preds = %path28
  br label %path30

path30:                                           ; preds = %path29
  br label %path31

path31:                                           ; preds = %path30
  br label %path32

path32:                                           ; preds = %path31
  %unrelated = add i32 %0, 1
  br label %path33

path33:                                           ; preds = %path32
  br label %path34

path34:                                           ; preds = %path33
  br label %path35

path35:                                           ; preds = %path34
  br label %path36

path36:                                           ; preds = %path35
  br label %path37

path37:                                           ; preds = %path36
  br label %path38

path38:                                           ; preds = %path37
  br label %path39

path39:                                           ; preds = %path38
  br label %path40

path40:                                           ; preds = %path39
  br label %path41

path41:                                           ; preds = %path40
  br label %path42

path42:                                           ; preds = %path41
  br label %path43

path43:                                           ; preds = %path42
  br label %path44

path44:                                           ; preds = %path43
  br label %path45

path45:                                           ; preds = %path44
  br label %path46

path46:                                           ; preds = %path45
  br label %path47

path47:                                           ; preds = %path46
  ret void
}

declare i1 @jeandle.check_instanceof(ptr, ptr nonnull)
