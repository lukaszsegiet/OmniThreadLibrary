object frmTestOtlComm: TfrmTestOtlComm
  Left = 0
  Top = 0
  Caption = 'OtlComm tester'
  ClientHeight = 286
  ClientWidth = 426
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -11
  Font.Name = 'Tahoma'
  Font.Style = []
  OldCreateOrder = False
  PixelsPerInch = 96
  TextHeight = 13
  object lbLog: TListBox
    Left = 89
    Top = 0
    Width = 337
    Height = 286
    Align = alRight
    ItemHeight = 13
    TabOrder = 0
    ExplicitTop = 8
  end
  object btnRunTests: TButton
    Left = 8
    Top = 8
    Width = 75
    Height = 25
    Caption = 'Test'
    TabOrder = 1
    OnClick = btnRunTestsClick
  end
  object OmniTaskEventDispatch1: TOmniTaskEventDispatch
    OnTaskMessage = OmniTaskEventDispatch1TaskMessage
    Left = 8
    Top = 248
  end
end