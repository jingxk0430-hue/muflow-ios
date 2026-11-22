// Authored interoperability fixture; 8 second scene, native text + vector path.
def text title {
  content = "Infuse 弹幕 · BAS"
  x = 50%
  y = 35%
  anchorX = 0.5
  anchorY = 0.5
  fontSize = 5%
  color = 0x00a1d6
  strokeColor = 0xffffff
  strokeWidth = 1
  alpha = 0
  duration = 8s
}
def text caption {
  content = "文字 · 图形 · 时间线"
  parent = "title"
  x = 50%
  y = 120%
  fontSize = 2.4%
  anchorX = 0.5
  duration = 8s
}
def path badge {
  d = "M 0 12 L 12 0 L 24 12 L 12 24 Z"
  viewBox = "0 0 24 24"
  x = 20%
  y = 60%
  width = 4%
  fillColor = 0xff6699
  borderColor = 0xffffff
  borderWidth = 1
  duration = 8s
}
def button label {
  text = "本地 BAS"
  x = 43%
  y = 72%
  fontSize = 2.5%
  textColor = 0xffffff
  fillColor = 0x00a1d6
  duration = 8s
}
{
  set title { alpha = 1 } 1s, "ease-out"
  set badge { x = 76% } 4s, "ease-in-out"
}
then {
  set title { color = 0xff6699 } 2s
  set badge { x = 20% } 2s
}
then set title { alpha = 0 } 2s
