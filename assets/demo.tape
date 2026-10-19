# stakrr demo recording: run `zig build && vhs assets/demo.tape` from the repo root
# https://github.com/charmbracelet/vhs

Output assets/demo.gif

Set Shell "bash"
Set FontFamily "JetBrains Mono"
Set FontSize 20
Set Width 1200
Set Height 600
Set Padding 32
Set Margin 0
Set WindowBar ""
Set TypingSpeed 45ms
Set Theme { "name": "stakrr", "background": "#0a0a0f", "foreground": "#e6e6f0", "cursor": "#00f0ff", "selection": "#1c1c28", "black": "#0a0a0f", "red": "#ff2a6d", "green": "#00f0ff", "yellow": "#f5f749", "blue": "#00f0ff", "magenta": "#ff2a6d", "cyan": "#00f0ff", "white": "#e6e6f0", "brightBlack": "#5c5c70", "brightRed": "#ff2a6d", "brightGreen": "#00f0ff", "brightYellow": "#f5f749", "brightBlue": "#00f0ff", "brightMagenta": "#ff2a6d", "brightCyan": "#00f0ff", "brightWhite": "#ffffff" }

# throwaway repo with a few commits on a rolling branch
Hide
Type `export PATH="$PWD/zig-out/bin:$PATH" PS1='\[\e[35m\]›\[\e[0m\] ' GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1` Enter
Type `cd "$(mktemp -d)" && git init -q -b main && c() { git -c user.name=demo -c user.email=demo@stakrr.local commit -q --allow-empty -m "$1"; }` Enter
Type `c base && git switch -q -c shipit && c models && c api && c ui && c wip && clear` Enter
Show

Type "git log --oneline" Sleep 300ms Enter
Sleep 1.5s
Type "stakrr init --base main" Sleep 300ms Enter
Sleep 1s
Type "stakrr cut models --at HEAD~3" Sleep 300ms Enter
Sleep 1s
Type "stakrr cut api-and-ui --at HEAD~1" Sleep 300ms Enter
Sleep 1s
Type "stakrr status" Sleep 300ms Enter
Sleep 4s
