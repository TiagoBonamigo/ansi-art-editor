#!/usr/bin/env bash
# ============================================================================
# ANSI Art Editor - A full-featured terminal-based ANSI art editor
# ============================================================================
# Controls:
#   Arrow keys    - Move cursor
#   Space         - Place character with current colors
#   Tab           - Cycle drawing character
#   F1/1          - Foreground color picker
#   F2/2          - Background color picker
#   F3/3          - Character picker
#   F4/4          - Toggle bold/bright
#   F5/5          - Toggle blink
#   Ctrl+S / S    - Save file
#   Ctrl+O / O    - Open/load file
#   Ctrl+N / N    - New canvas
#   Ctrl+Z / U    - Undo
#   Ctrl+Y / R    - Redo
#   F / f         - Fill tool toggle
#   L / l         - Line tool toggle
#   K / k         - Polyline/continuous line tool
#   B / b         - Box tool toggle
#   I / i         - Ellipse/oval tool (center + edge)
#   E / e         - Eraser toggle
#   C / c         - Copy mode
#   V / v         - Paste
#   P / p         - Eyedropper/pick color from canvas
#   G / g         - Toggle grid overlay
#   + / -         - Resize canvas
#   Mouse LClick  - Move cursor & activate tool
#   Mouse RClick  - Eyedropper (pick color)
#   Mouse Drag    - Draw/erase while dragging
#   Mouse Wheel   - Scroll cursor up/down
#   M / m         - Toggle mouse on/off
#   H / h / ?     - Help screen
#   Q / q         - Quit
# ============================================================================

set -u

# --- Configuration ---
CANVAS_W=200
CANVAS_H=200
MAX_UNDO=50
FILENAME="untitled.ans"
MODIFIED=0

# --- Viewport ---
# The viewport is the visible portion of the canvas, sized to fit the terminal.
# VIEWPORT_W/H are computed at startup from terminal size.
VIEWPORT_W=78       # Leave 2 cols for right scrollbar
VIEWPORT_H=22       # Leave rows for status bars
SCROLL_X=0
SCROLL_Y=0

# --- State ---
CUR_X=0
CUR_Y=0
CUR_FG=7       # White
CUR_BG=0       # Black
CUR_CHAR=" "
CUR_BOLD=0
CUR_BLINK=0
DRAW_CHARS=(' ' '#' '@' '*' '.' ':' '=' '+' '-' '|' '/' '\\' '~' '%' '&' '$'
            '!' '?' '<' '>' '^' 'v' 'o' 'O' '0' 'X' 'x')
DRAW_CHAR_IDX=1
TOOL="draw"     # draw, fill, line, polyline, box, ellipse, erase, copy
GRID_ON=0
LINE_START_X=-1
LINE_START_Y=-1
POLYLINE_LAST_X=-1
POLYLINE_LAST_Y=-1
BOX_START_X=-1
BOX_START_Y=-1
ELLIPSE_START_X=-1
ELLIPSE_START_Y=-1
COPY_BUF=()
COPY_W=0
COPY_H=0
COPY_START_X=-1
COPY_START_Y=-1
COPY_END_X=-1
COPY_END_Y=-1
SELECTING=0
MOUSE_ON=1          # Mouse enabled by default
MOUSE_DRAGGING=0    # Currently dragging
MOUSE_BTN=-1        # Last mouse button pressed

# Color names for display
COLOR_NAMES=("Black" "Red" "Green" "Yellow" "Blue" "Magenta" "Cyan" "White"
             "BrBlack" "BrRed" "BrGreen" "BrYellow" "BrBlue" "BrMagenta" "BrCyan" "BrWhite")

# --- Canvas arrays ---
# Each cell: char, fg, bg, bold, blink
declare -a CANVAS_CHAR
declare -a CANVAS_FG
declare -a CANVAS_BG
declare -a CANVAS_BOLD
declare -a CANVAS_BLINK

# --- Undo/Redo stacks (stored as serialized snapshots) ---
declare -a UNDO_STACK
declare -a REDO_STACK
UNDO_COUNT=0
REDO_COUNT=0

# ============================================================================
# Terminal setup
# ============================================================================
# ============================================================================
# Viewport / terminal size
# ============================================================================
detect_terminal_size() {
    local rows cols
    rows=$(tput lines 2>/dev/null || echo 30)
    cols=$(tput cols 2>/dev/null || echo 80)
    VIEWPORT_W=$(( cols - 2 ))   # 1 col for right scrollbar + 1 padding
    VIEWPORT_H=$(( rows - 4 ))   # 3 status bar lines + 1 padding
    (( VIEWPORT_W > CANVAS_W )) && VIEWPORT_W=$CANVAS_W
    (( VIEWPORT_H > CANVAS_H )) && VIEWPORT_H=$CANVAS_H
    (( VIEWPORT_W < 10 )) && VIEWPORT_W=10
    (( VIEWPORT_H < 5 )) && VIEWPORT_H=5
}

clamp_scroll() {
    local max_sx=$(( CANVAS_W - VIEWPORT_W ))
    local max_sy=$(( CANVAS_H - VIEWPORT_H ))
    (( max_sx < 0 )) && max_sx=0
    (( max_sy < 0 )) && max_sy=0
    (( SCROLL_X < 0 )) && SCROLL_X=0
    (( SCROLL_Y < 0 )) && SCROLL_Y=0
    (( SCROLL_X > max_sx )) && SCROLL_X=$max_sx
    (( SCROLL_Y > max_sy )) && SCROLL_Y=$max_sy
}

# Auto-scroll viewport to keep cursor visible
follow_cursor() {
    local margin=2
    # Horizontal
    if (( CUR_X < SCROLL_X + margin )); then
        SCROLL_X=$(( CUR_X - margin ))
    elif (( CUR_X >= SCROLL_X + VIEWPORT_W - margin )); then
        SCROLL_X=$(( CUR_X - VIEWPORT_W + margin + 1 ))
    fi
    # Vertical
    if (( CUR_Y < SCROLL_Y + margin )); then
        SCROLL_Y=$(( CUR_Y - margin ))
    elif (( CUR_Y >= SCROLL_Y + VIEWPORT_H - margin )); then
        SCROLL_Y=$(( CUR_Y - VIEWPORT_H + margin + 1 ))
    fi
    clamp_scroll
}

enable_mouse() {
    printf '\e[?1000h'     # Enable basic mouse tracking (clicks)
    printf '\e[?1002h'     # Enable button-event tracking (drag)
    printf '\e[?1006h'     # Enable SGR extended mouse mode (supports >223 cols)
}

disable_mouse() {
    printf '\e[?1006l'
    printf '\e[?1002l'
    printf '\e[?1000l'
}

setup_terminal() {
    stty -echo -icanon min 1 time 0 2>/dev/null
    printf '\e[?25l'       # Hide cursor
    printf '\e[?1049h'     # Alternate screen buffer
    printf '\e[2J'         # Clear screen
    detect_terminal_size
    if (( MOUSE_ON )); then
        enable_mouse
    fi
}

restore_terminal() {
    disable_mouse
    printf '\e[0m'
    printf '\e[?25h'       # Show cursor
    printf '\e[?1049l'     # Restore screen buffer
    stty echo icanon 2>/dev/null
}

# ============================================================================
# Canvas operations
# ============================================================================
cell_idx() {
    echo $(( $1 + $2 * CANVAS_W ))
}

init_canvas() {
    CANVAS_CHAR=()
    CANVAS_FG=()
    CANVAS_BG=()
    CANVAS_BOLD=()
    CANVAS_BLINK=()
    local total=$(( CANVAS_W * CANVAS_H ))
    for (( i=0; i<total; i++ )); do
        CANVAS_CHAR[$i]=" "
        CANVAS_FG[$i]=7
        CANVAS_BG[$i]=0
        CANVAS_BOLD[$i]=0
        CANVAS_BLINK[$i]=0
    done
    MODIFIED=0
    UNDO_STACK=()
    REDO_STACK=()
    UNDO_COUNT=0
    REDO_COUNT=0
}

# Resize canvas, preserving existing content
resize_canvas() {
    local new_w=$1 new_h=$2
    (( new_w < 20 )) && new_w=20
    (( new_h < 10 )) && new_h=10
    (( new_w > 1000 )) && new_w=1000
    (( new_h > 1000 )) && new_h=1000
    if (( new_w == CANVAS_W && new_h == CANVAS_H )); then return; fi

    # Clear undo/redo since snapshots are tied to the old dimensions
    UNDO_STACK=(); REDO_STACK=(); UNDO_COUNT=0; REDO_COUNT=0

    # Copy existing data
    local -a old_char=("${CANVAS_CHAR[@]}")
    local -a old_fg=("${CANVAS_FG[@]}")
    local -a old_bg=("${CANVAS_BG[@]}")
    local -a old_bold=("${CANVAS_BOLD[@]}")
    local -a old_blink=("${CANVAS_BLINK[@]}")
    local old_w=$CANVAS_W old_h=$CANVAS_H

    CANVAS_W=$new_w
    CANVAS_H=$new_h

    # Reinitialize arrays
    local total=$(( CANVAS_W * CANVAS_H ))
    CANVAS_CHAR=()
    CANVAS_FG=()
    CANVAS_BG=()
    CANVAS_BOLD=()
    CANVAS_BLINK=()
    for (( i=0; i<total; i++ )); do
        CANVAS_CHAR[$i]=" "
        CANVAS_FG[$i]=7
        CANVAS_BG[$i]=0
        CANVAS_BOLD[$i]=0
        CANVAS_BLINK[$i]=0
    done

    # Copy old content that fits
    local copy_w=$(( old_w < CANVAS_W ? old_w : CANVAS_W ))
    local copy_h=$(( old_h < CANVAS_H ? old_h : CANVAS_H ))
    for (( y=0; y<copy_h; y++ )); do
        for (( x=0; x<copy_w; x++ )); do
            local old_idx=$(( x + y * old_w ))
            local new_idx=$(( x + y * CANVAS_W ))
            CANVAS_CHAR[$new_idx]="${old_char[$old_idx]}"
            CANVAS_FG[$new_idx]="${old_fg[$old_idx]}"
            CANVAS_BG[$new_idx]="${old_bg[$old_idx]}"
            CANVAS_BOLD[$new_idx]="${old_bold[$old_idx]}"
            CANVAS_BLINK[$new_idx]="${old_blink[$old_idx]}"
        done
    done

    # Clamp cursor
    (( CUR_X >= CANVAS_W )) && CUR_X=$(( CANVAS_W - 1 ))
    (( CUR_Y >= CANVAS_H )) && CUR_Y=$(( CANVAS_H - 1 ))
    clamp_scroll
    MODIFIED=1

    # Clear and redraw
    printf '\e[2J'
}

# Snapshot canvas state for undo
snapshot_canvas() {
    local snap=""
    local total=$(( CANVAS_W * CANVAS_H ))
    for (( i=0; i<total; i++ )); do
        snap+="${CANVAS_CHAR[$i]}|${CANVAS_FG[$i]}|${CANVAS_BG[$i]}|${CANVAS_BOLD[$i]}|${CANVAS_BLINK[$i]};"
    done
    UNDO_STACK[$UNDO_COUNT]="$snap"
    (( UNDO_COUNT++ ))
    if (( UNDO_COUNT > MAX_UNDO )); then
        # Shift stack
        for (( i=0; i<MAX_UNDO; i++ )); do
            UNDO_STACK[$i]="${UNDO_STACK[$((i+1))]}"
        done
        (( UNDO_COUNT-- ))
    fi
    # Clear redo stack
    REDO_STACK=()
    REDO_COUNT=0
}

restore_snapshot() {
    local snap="$1"
    local total=$(( CANVAS_W * CANVAS_H ))
    IFS=';' read -ra cells <<< "$snap"
    for (( i=0; i<total; i++ )); do
        IFS='|' read -r ch fg bg bd bl <<< "${cells[$i]}"
        CANVAS_CHAR[$i]="$ch"
        CANVAS_FG[$i]="$fg"
        CANVAS_BG[$i]="$bg"
        CANVAS_BOLD[$i]="$bd"
        CANVAS_BLINK[$i]="$bl"
    done
}

do_undo() {
    if (( UNDO_COUNT <= 0 )); then return; fi
    # Save current state to redo
    local snap=""
    local total=$(( CANVAS_W * CANVAS_H ))
    for (( i=0; i<total; i++ )); do
        snap+="${CANVAS_CHAR[$i]}|${CANVAS_FG[$i]}|${CANVAS_BG[$i]}|${CANVAS_BOLD[$i]}|${CANVAS_BLINK[$i]};"
    done
    REDO_STACK[$REDO_COUNT]="$snap"
    (( REDO_COUNT++ ))
    # Restore from undo
    (( UNDO_COUNT-- ))
    restore_snapshot "${UNDO_STACK[$UNDO_COUNT]}"
    unset 'UNDO_STACK[$UNDO_COUNT]'
}

do_redo() {
    if (( REDO_COUNT <= 0 )); then return; fi
    # Save current to undo
    local snap=""
    local total=$(( CANVAS_W * CANVAS_H ))
    for (( i=0; i<total; i++ )); do
        snap+="${CANVAS_CHAR[$i]}|${CANVAS_FG[$i]}|${CANVAS_BG[$i]}|${CANVAS_BOLD[$i]}|${CANVAS_BLINK[$i]};"
    done
    UNDO_STACK[$UNDO_COUNT]="$snap"
    (( UNDO_COUNT++ ))
    # Restore from redo
    (( REDO_COUNT-- ))
    restore_snapshot "${REDO_STACK[$REDO_COUNT]}"
    unset 'REDO_STACK[$REDO_COUNT]'
}

# ============================================================================
# Drawing primitives
# ============================================================================
set_cell() {
    local x=$1 y=$2 ch="$3" fg=$4 bg=$5 bd=$6 bl=$7
    if (( x < 0 || x >= CANVAS_W || y < 0 || y >= CANVAS_H )); then return; fi
    local idx=$(( x + y * CANVAS_W ))
    CANVAS_CHAR[$idx]="$ch"
    CANVAS_FG[$idx]=$fg
    CANVAS_BG[$idx]=$bg
    CANVAS_BOLD[$idx]=$bd
    CANVAS_BLINK[$idx]=$bl
    MODIFIED=1
}

get_cell_char() {
    local idx=$(( $1 + $2 * CANVAS_W ))
    echo "${CANVAS_CHAR[$idx]}"
}

get_cell_fg() {
    local idx=$(( $1 + $2 * CANVAS_W ))
    echo "${CANVAS_FG[$idx]}"
}

get_cell_bg() {
    local idx=$(( $1 + $2 * CANVAS_W ))
    echo "${CANVAS_BG[$idx]}"
}

draw_at_cursor() {
    snapshot_canvas
    set_cell "$CUR_X" "$CUR_Y" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
}

erase_at_cursor() {
    snapshot_canvas
    set_cell "$CUR_X" "$CUR_Y" " " 7 0 0 0
}

# Flood fill
flood_fill() {
    local sx=$1 sy=$2
    local idx=$(( sx + sy * CANVAS_W ))
    local orig_ch="${CANVAS_CHAR[$idx]}"
    local orig_fg="${CANVAS_FG[$idx]}"
    local orig_bg="${CANVAS_BG[$idx]}"

    # Don't fill if target matches source
    if [[ "$orig_ch" == "$CUR_CHAR" && "$orig_fg" == "$CUR_FG" && "$orig_bg" == "$CUR_BG" ]]; then
        return
    fi

    snapshot_canvas

    local -a stack=("$sx,$sy")
    while (( ${#stack[@]} > 0 )); do
        local last_idx=$(( ${#stack[@]} - 1 ))
        local coord="${stack[$last_idx]}"
        unset 'stack[$last_idx]'
        stack=("${stack[@]+"${stack[@]}"}")

        local fx=${coord%,*}
        local fy=${coord#*,}

        if (( fx < 0 || fx >= CANVAS_W || fy < 0 || fy >= CANVAS_H )); then continue; fi

        local fidx=$(( fx + fy * CANVAS_W ))
        if [[ "${CANVAS_CHAR[$fidx]}" != "$orig_ch" || "${CANVAS_FG[$fidx]}" != "$orig_fg" || "${CANVAS_BG[$fidx]}" != "$orig_bg" ]]; then
            continue
        fi

        CANVAS_CHAR[$fidx]="$CUR_CHAR"
        CANVAS_FG[$fidx]=$CUR_FG
        CANVAS_BG[$fidx]=$CUR_BG
        CANVAS_BOLD[$fidx]=$CUR_BOLD
        CANVAS_BLINK[$fidx]=$CUR_BLINK

        stack+=("$((fx-1)),$fy" "$((fx+1)),$fy" "$fx,$((fy-1))" "$fx,$((fy+1))")
    done
    MODIFIED=1
}

# Draw line (Bresenham's)
draw_line() {
    local x0=$1 y0=$2 x1=$3 y1=$4
    snapshot_canvas
    local dx=$(( x1 - x0 ))
    local dy=$(( y1 - y0 ))
    (( dx < 0 )) && dx=$(( -dx ))
    (( dy < 0 )) && dy=$(( -dy ))
    local sx=-1; (( x0 < x1 )) && sx=1
    local sy=-1; (( y0 < y1 )) && sy=1
    local err=$(( dx - dy ))
    while true; do
        set_cell "$x0" "$y0" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
        if (( x0 == x1 && y0 == y1 )); then break; fi
        local e2=$(( 2 * err ))
        if (( e2 > -dy )); then (( err -= dy )); (( x0 += sx )); fi
        if (( e2 < dx )); then (( err += dx )); (( y0 += sy )); fi
    done
}

# Draw box outline
draw_box() {
    local x0=$1 y0=$2 x1=$3 y1=$4
    snapshot_canvas
    # Normalize coordinates
    local lx=$x0 ly=$y0 rx=$x1 ry=$y1
    (( x0 > x1 )) && lx=$x1 && rx=$x0
    (( y0 > y1 )) && ly=$y1 && ry=$y0
    # Top and bottom
    for (( x=lx; x<=rx; x++ )); do
        set_cell "$x" "$ly" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
        set_cell "$x" "$ry" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
    done
    # Left and right
    for (( y=ly; y<=ry; y++ )); do
        set_cell "$lx" "$y" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
        set_cell "$rx" "$y" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
    done
}

# Draw ellipse (midpoint algorithm)
# First click = center, second click = edge point defining radii
draw_ellipse() {
    local cx=$1 cy=$2 ex=$3 ey=$4
    snapshot_canvas

    # Compute radii from center to edge point
    local rx=$(( ex - cx ))
    local ry=$(( ey - cy ))
    (( rx < 0 )) && rx=$(( -rx ))
    (( ry < 0 )) && ry=$(( -ry ))
    (( rx == 0 )) && rx=1
    (( ry == 0 )) && ry=1

    # Midpoint ellipse algorithm
    local x=0
    local y=$ry
    local rx2=$(( rx * rx ))
    local ry2=$(( ry * ry ))
    local two_rx2=$(( 2 * rx2 ))
    local two_ry2=$(( 2 * ry2 ))
    local px=0
    local py=$(( two_rx2 * y ))

    # Plot 4 symmetric points
    _ellipse_plot4() {
        set_cell "$(( cx + $1 ))" "$(( cy + $2 ))" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
        set_cell "$(( cx - $1 ))" "$(( cy + $2 ))" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
        set_cell "$(( cx + $1 ))" "$(( cy - $2 ))" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
        set_cell "$(( cx - $1 ))" "$(( cy - $2 ))" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
    }

    # Region 1: dy/dx < 1
    local p=$(( ry2 - rx2 * ry + rx2 / 4 ))
    while (( px < py )); do
        _ellipse_plot4 "$x" "$y"
        (( x++ ))
        (( px += two_ry2 ))
        if (( p < 0 )); then
            (( p += ry2 + px ))
        else
            (( y-- ))
            (( py -= two_rx2 ))
            (( p += ry2 + px - py ))
        fi
    done

    # Region 2: dy/dx >= 1
    p=$(( ry2 * (2 * x + 1) * (2 * x + 1) / 4 + rx2 * (y - 1) * (y - 1) - rx2 * ry2 ))
    while (( y >= 0 )); do
        _ellipse_plot4 "$x" "$y"
        (( y-- ))
        (( py -= two_rx2 ))
        if (( p > 0 )); then
            (( p += rx2 - py ))
        else
            (( x++ ))
            (( px += two_ry2 ))
            (( p += rx2 - py + px ))
        fi
    done

    unset -f _ellipse_plot4
}

# Copy region
do_copy() {
    if (( COPY_START_X < 0 || COPY_END_X < 0 )); then return; fi
    local x0=$COPY_START_X y0=$COPY_START_Y x1=$COPY_END_X y1=$COPY_END_Y
    (( x0 > x1 )) && { local t=$x0; x0=$x1; x1=$t; }
    (( y0 > y1 )) && { local t=$y0; y0=$y1; y1=$t; }
    COPY_W=$(( x1 - x0 + 1 ))
    COPY_H=$(( y1 - y0 + 1 ))
    COPY_BUF=()
    local ci=0
    for (( y=y0; y<=y1; y++ )); do
        for (( x=x0; x<=x1; x++ )); do
            local idx=$(( x + y * CANVAS_W ))
            COPY_BUF[$ci]="${CANVAS_CHAR[$idx]}|${CANVAS_FG[$idx]}|${CANVAS_BG[$idx]}|${CANVAS_BOLD[$idx]}|${CANVAS_BLINK[$idx]}"
            (( ci++ ))
        done
    done
}

do_paste() {
    if (( COPY_W <= 0 || COPY_H <= 0 )); then return; fi
    snapshot_canvas
    local ci=0
    for (( dy=0; dy<COPY_H; dy++ )); do
        for (( dx=0; dx<COPY_W; dx++ )); do
            local px=$(( CUR_X + dx ))
            local py=$(( CUR_Y + dy ))
            if (( px < CANVAS_W && py < CANVAS_H )); then
                IFS='|' read -r ch fg bg bd bl <<< "${COPY_BUF[$ci]}"
                set_cell "$px" "$py" "$ch" "$fg" "$bg" "$bd" "$bl"
            fi
            (( ci++ ))
        done
    done
}

# ============================================================================
# File I/O
# ============================================================================
save_file() {
    local fname="$1"
    local out=""
    local prev_fg=-1 prev_bg=-1 prev_bold=-1 prev_blink=-1

    for (( y=0; y<CANVAS_H; y++ )); do
        prev_fg=-1; prev_bg=-1; prev_bold=-1; prev_blink=-1
        for (( x=0; x<CANVAS_W; x++ )); do
            local idx=$(( x + y * CANVAS_W ))
            local fg=${CANVAS_FG[$idx]}
            local bg=${CANVAS_BG[$idx]}
            local bd=${CANVAS_BOLD[$idx]}
            local bl=${CANVAS_BLINK[$idx]}
            local ch="${CANVAS_CHAR[$idx]}"

            # Build ANSI escape if attributes changed
            if (( fg != prev_fg || bg != prev_bg || bd != prev_bold || bl != prev_blink )); then
                out+="\e[0"
                (( bd )) && out+=";1"
                (( bl )) && out+=";5"
                if (( fg < 8 )); then
                    out+=";$((30+fg))"
                else
                    out+=";$((82+fg))"  # 90-97
                fi
                if (( bg < 8 )); then
                    out+=";$((40+bg))"
                else
                    out+=";$((92+bg))"  # 100-107
                fi
                out+="m"
                prev_fg=$fg; prev_bg=$bg; prev_bold=$bd; prev_blink=$bl
            fi
            out+="$ch"
        done
        out+="\e[0m\n"
    done
    printf '%b' "$out" > "$fname"
    MODIFIED=0
    FILENAME="$fname"
}

load_file() {
    local fname="$1"
    if [[ ! -f "$fname" ]]; then return 1; fi

    init_canvas
    local y=0
    local x=0
    local fg=7 bg=0 bold=0 blink=0

    # Read file and parse ANSI sequences
    while IFS= read -r -n1 ch || [[ -n "$ch" ]]; do
        if [[ "$ch" == $'\e' ]]; then
            # Read escape sequence
            local seq=""
            IFS= read -r -n1 ch
            if [[ "$ch" == "[" ]]; then
                while IFS= read -r -n1 ch; do
                    if [[ "$ch" =~ [a-zA-Z] ]]; then
                        if [[ "$ch" == "m" ]]; then
                            # Parse SGR parameters
                            IFS=';' read -ra params <<< "$seq"
                            for p in "${params[@]}"; do
                                case $p in
                                    0)  fg=7; bg=0; bold=0; blink=0 ;;
                                    1)  bold=1 ;;
                                    5)  blink=1 ;;
                                    22) bold=0 ;;
                                    25) blink=0 ;;
                                    3[0-7]) fg=$(( ${p} - 30 )) ;;
                                    4[0-7]) bg=$(( ${p} - 40 )) ;;
                                    9[0-7]) fg=$(( ${p} - 82 )) ;;
                                    10[0-7]) bg=$(( ${p} - 92 )) ;;
                                esac
                            done
                        fi
                        break
                    fi
                    seq+="$ch"
                done
            fi
        elif [[ "$ch" == $'\n' ]]; then
            (( y++ ))
            x=0
            if (( y >= CANVAS_H )); then break; fi
        else
            if (( x < CANVAS_W && y < CANVAS_H )); then
                local idx=$(( x + y * CANVAS_W ))
                CANVAS_CHAR[$idx]="$ch"
                CANVAS_FG[$idx]=$fg
                CANVAS_BG[$idx]=$bg
                CANVAS_BOLD[$idx]=$bold
                CANVAS_BLINK[$idx]=$blink
            fi
            (( x++ ))
        fi
    done < "$fname"

    FILENAME="$fname"
    MODIFIED=0
}

# Export as plain text (no ANSI)
export_plain() {
    local fname="$1"
    local out=""
    for (( y=0; y<CANVAS_H; y++ )); do
        for (( x=0; x<CANVAS_W; x++ )); do
            local idx=$(( x + y * CANVAS_W ))
            out+="${CANVAS_CHAR[$idx]}"
        done
        out+=$'\n'
    done
    printf "%s" "$out" > "$fname"
}

# ============================================================================
# Rendering
# ============================================================================
render_canvas() {
    follow_cursor
    local buf=""
    buf+="\e[1;1H"  # Move to top-left

    # Compute scrollbar positions
    local max_sx=$(( CANVAS_W - VIEWPORT_W ))
    local max_sy=$(( CANVAS_H - VIEWPORT_H ))
    (( max_sx < 1 )) && max_sx=1
    (( max_sy < 1 )) && max_sy=1
    local vscroll_pos=$(( SCROLL_Y * (VIEWPORT_H - 1) / max_sy ))
    local hscroll_pos=$(( SCROLL_X * (VIEWPORT_W - 1) / max_sx ))

    for (( vy=0; vy<VIEWPORT_H; vy++ )); do
        local y=$(( vy + SCROLL_Y ))
        local prev_fg=-1 prev_bg=-1 prev_bold=-1 prev_blink=-1
        for (( vx=0; vx<VIEWPORT_W; vx++ )); do
            local x=$(( vx + SCROLL_X ))
            local idx=$(( x + y * CANVAS_W ))
            local fg=${CANVAS_FG[$idx]}
            local bg=${CANVAS_BG[$idx]}
            local bd=${CANVAS_BOLD[$idx]}
            local bl=${CANVAS_BLINK[$idx]}
            local ch="${CANVAS_CHAR[$idx]}"

            # Grid overlay
            if (( GRID_ON && (x % 10 == 0 || y % 5 == 0) )); then
                if [[ "$ch" == " " ]]; then
                    if (( x % 10 == 0 && y % 5 == 0 )); then
                        ch="+"
                    elif (( x % 10 == 0 )); then
                        ch="|"
                    else
                        ch="-"
                    fi
                    fg=8  # Dark gray for grid
                    bd=0; bl=0
                fi
            fi

            # Selection highlight
            if (( SELECTING && TOOL == "copy" )); then
                local in_sel=0
                if (( COPY_START_X >= 0 )); then
                    local sx=$COPY_START_X sy=$COPY_START_Y ex=$CUR_X ey=$CUR_Y
                    (( sx > ex )) && { local t=$sx; sx=$ex; ex=$t; }
                    (( sy > ey )) && { local t=$sy; sy=$ey; ey=$t; }
                    if (( x >= sx && x <= ex && y >= sy && y <= ey )); then
                        in_sel=1
                    fi
                fi
                if (( in_sel )); then
                    local tmp=$fg; fg=$bg; bg=$tmp
                fi
            fi

            # Cursor
            if (( x == CUR_X && y == CUR_Y )); then
                local tmp=$fg; fg=$bg; bg=$tmp
                if (( bg == 0 && fg == 0 )); then fg=7; fi
            fi

            # Emit escape if attributes changed
            if (( fg != prev_fg || bg != prev_bg || bd != prev_bold || bl != prev_blink )); then
                buf+="\e[0"
                (( bd )) && buf+=";1"
                (( bl )) && buf+=";5"
                if (( fg < 8 )); then
                    buf+=";$((30+fg))"
                else
                    buf+=";$((82+fg))"
                fi
                if (( bg < 8 )); then
                    buf+=";$((40+bg))"
                else
                    buf+=";$((92+bg))"
                fi
                buf+="m"
                prev_fg=$fg; prev_bg=$bg; prev_bold=$bd; prev_blink=$bl
            fi
            buf+="$ch"
        done
        buf+="\e[0m"

        # Right scrollbar (vertical)
        if (( vy == vscroll_pos )); then
            buf+="\e[0;97;44m#\e[0m"
        else
            buf+="\e[0;90m|\e[0m"
        fi

        if (( vy < VIEWPORT_H - 1 )); then
            buf+="\n"
        fi
    done

    # Bottom scrollbar (horizontal) on next line
    buf+="\n"
    for (( vx=0; vx<VIEWPORT_W; vx++ )); do
        if (( vx == hscroll_pos )); then
            buf+="\e[0;97;44m#\e[0m"
        else
            buf+="\e[0;90m-\e[0m"
        fi
    done
    buf+=" "  # corner

    printf '%b' "$buf"
}

render_status_bar() {
    local row=$(( VIEWPORT_H + 2 ))  # After viewport + h-scrollbar

    # Status bar line 1 - tool & position info
    printf "\e[${row};1H\e[0;97;44m"
    local mod_flag=" "
    (( MODIFIED )) && mod_flag="*"

    local tool_name
    case "$TOOL" in
        draw)  tool_name="DRAW"  ;;
        fill)  tool_name="FILL"  ;;
        line)     tool_name="LINE"     ;;
        polyline) tool_name="POLYLINE" ;;
        box)     tool_name="BOX"     ;;
        ellipse) tool_name="ELLIPSE" ;;
        erase)   tool_name="ERASE"   ;;
        copy)  tool_name="COPY"  ;;
        *)     tool_name="???"   ;;
    esac

    local attr=""
    (( CUR_BOLD )) && attr+="B"
    (( CUR_BLINK )) && attr+="K"
    [[ -z "$attr" ]] && attr="-"

    printf " %-12s${mod_flag}| Pos:(%03d,%03d) Canvas:%dx%d | Char:[%s] | Attr:[%s] | " \
        "$FILENAME" "$CUR_X" "$CUR_Y" "$CANVAS_W" "$CANVAS_H" "$CUR_CHAR" "$attr"

    # Show foreground color swatch
    printf "FG:"
    if (( CUR_FG < 8 )); then
        printf "\e[%dm" $((30+CUR_FG))
    else
        printf "\e[%dm" $((82+CUR_FG))
    fi
    printf "\e[44m%-8s\e[0;97;44m " "${COLOR_NAMES[$CUR_FG]}"

    # Show background color swatch
    printf "BG:"
    if (( CUR_BG < 8 )); then
        printf "\e[%dm" $((40+CUR_BG))
    else
        printf "\e[%dm" $((92+CUR_BG))
    fi
    printf "  \e[0;97;44m%-8s " "${COLOR_NAMES[$CUR_BG]}"

    printf "| Tool:[%s] " "$tool_name"

    # Pad rest of line
    printf "%*s" 20 ""
    printf "\e[0m"

    # Status bar line 2 - color palette display
    (( row++ ))
    printf "\e[${row};1H\e[0;97;40m"
    printf " FG: "
    for (( c=0; c<16; c++ )); do
        if (( c < 8 )); then
            printf "\e[%dm" $((30+c))
        else
            printf "\e[%dm" $((82+c))
        fi
        if (( c == CUR_FG )); then
            printf "\e[4m[%X]\e[24m" $c
        else
            printf " %X " $c
        fi
    done
    printf "\e[0;97;40m  BG: "
    for (( c=0; c<16; c++ )); do
        if (( c < 8 )); then
            printf "\e[%dm" $((40+c))
        else
            printf "\e[%dm" $((92+c))
        fi
        if (( c == CUR_BG )); then
            printf "\e[7m[%X]\e[27m" $c
        else
            printf " %X " $c
        fi
    done
    printf "\e[0;97;40m Undo:%d %*s\e[0m" "$UNDO_COUNT" 10 ""

    # Status bar line 3 - help hint
    (( row++ ))
    printf "\e[${row};1H\e[0;90;40m"
    local mouse_flag="ON"
    (( ! MOUSE_ON )) && mouse_flag="OFF"
    printf " [H]elp [Space]Draw [1]FG [2]BG [F]ill [L]ine [K]polyline [B]ox [I]ellipse [E]rase [U]ndo [S]ave [M]ouse:%s [Q]uit" "$mouse_flag"
    printf "%*s\e[0m" 10 ""
}

render_all() {
    render_canvas
    render_status_bar
}

# ============================================================================
# Interactive pickers
# ============================================================================
color_picker() {
    local mode=$1  # "fg" or "bg"
    local row=$(( VIEWPORT_H + 2 ))
    printf "\e[${row};1H\e[0;97;41m"
    if [[ "$mode" == "fg" ]]; then
        printf " SELECT FOREGROUND COLOR (0-F, Esc to cancel): "
    else
        printf " SELECT BACKGROUND COLOR (0-F, Esc to cancel): "
    fi
    printf "%*s\e[0m" 40 ""

    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\e')
                # Check for escape vs function key
                if IFS= read -rsn1 -t 0.1 next; then
                    continue  # Ignore escape sequences
                fi
                return  # Plain escape - cancel
                ;;
            [0-9])
                if [[ "$mode" == "fg" ]]; then CUR_FG=$key; else CUR_BG=$key; fi
                return
                ;;
            [a-fA-F])
                local val
                val=$(printf '%d' "0x${key,,}")
                if [[ "$mode" == "fg" ]]; then CUR_FG=$val; else CUR_BG=$val; fi
                return
                ;;
        esac
    done
}

char_picker() {
    local row=$(( VIEWPORT_H + 2 ))
    printf "\e[${row};1H\e[0;97;42m"
    printf " CHARACTER PICKER - Press a key to select (Esc cancel): "
    printf "%*s\e[0m" 30 ""

    # Show available chars
    (( row++ ))
    printf "\e[${row};1H\e[0;97;40m"
    printf " Preset: "
    for (( i=0; i<${#DRAW_CHARS[@]}; i++ )); do
        if (( i == DRAW_CHAR_IDX )); then
            printf "\e[7m[%s]\e[27m" "${DRAW_CHARS[$i]}"
        else
            printf " %s " "${DRAW_CHARS[$i]}"
        fi
    done
    printf "%*s\e[0m" 10 ""

    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\e')
                if IFS= read -rsn1 -t 0.1 next; then continue; fi
                return
                ;;
            *)
                if [[ -n "$key" ]]; then
                    CUR_CHAR="$key"
                    return
                fi
                ;;
        esac
    done
}

# Prompt for filename
prompt_filename() {
    local prompt_msg="$1"
    local default="$2"
    local row=$(( VIEWPORT_H + 2 ))
    printf "\e[${row};1H\e[0;97;45m"
    printf " %s [%s]: " "$prompt_msg" "$default"
    printf "%*s\e[0m" 30 ""
    printf "\e[?25h"  # Show cursor for typing

    local input=""
    while true; do
        IFS= read -rsn1 key
        case "$key" in
            $'\n'|"")
                if [[ -z "$input" ]]; then
                    input="$default"
                fi
                break
                ;;
            $'\177'|$'\b')  # Backspace
                if [[ -n "$input" ]]; then
                    input="${input%?}"
                    printf "\b \b"
                fi
                ;;
            $'\e')
                printf "\e[?25l"
                echo ""
                return 1
                ;;
            *)
                input+="$key"
                printf "%s" "$key"
                ;;
        esac
    done
    printf "\e[?25l"  # Hide cursor again
    echo "$input"
    return 0
}

# ============================================================================
# Help screen
# ============================================================================
show_help() {
    printf '\e[2J\e[1;1H'
    printf '\e[1;97m'
    cat << 'HELPEOF'
    ╔══════════════════════════════════════════════════════════════╗
    ║              ANSI ART EDITOR - HELP                         ║
    ╠══════════════════════════════════════════════════════════════╣
    ║                                                              ║
    ║  MOVEMENT & SCROLLING                                        ║
    ║    Arrow Keys .... Move cursor (viewport follows)           ║
    ║    Home/End ...... Start/end of row                          ║
    ║    PgUp/PgDn ..... Scroll up/down by one page               ║
    ║    + / - ......... Resize canvas (+/-10 each axis)          ║
    ║                                                              ║
    ║  DRAWING                                                     ║
    ║    Space ......... Place character with current colors       ║
    ║    Tab ........... Cycle to next preset character            ║
    ║    Shift+Tab ..... Cycle to previous character               ║
    ║    Delete ........ Clear current cell                        ║
    ║                                                              ║
    ║  COLORS & ATTRIBUTES                                         ║
    ║    1 / F1 ........ Foreground color picker                  ║
    ║    2 / F2 ........ Background color picker                  ║
    ║    3 / F3 ........ Character picker                         ║
    ║    4 / F4 ........ Toggle bold/bright                       ║
    ║    5 / F5 ........ Toggle blink                             ║
    ║    P ............. Eyedropper (pick colors from canvas)      ║
    ║                                                              ║
    ║  TOOLS                                                       ║
    ║    F ............. Flood fill tool                           ║
    ║    L ............. Line tool (click start, move, click end)  ║
    ║    K ............. Polyline (continuous chained lines)       ║
    ║    B ............. Box/rectangle tool                        ║
    ║    I ............. Ellipse/oval tool (center, then edge)    ║
    ║    E ............. Eraser tool                               ║
    ║    C ............. Copy mode (select region)                 ║
    ║    V ............. Paste copied region                       ║
    ║    D ............. Draw mode (default)                       ║
    ║                                                              ║
    ║  FILE                                                        ║
    ║    S / Ctrl+S .... Save file (.ans ANSI format)             ║
    ║    O / Ctrl+O .... Open/load file                           ║
    ║    N / Ctrl+N .... New canvas                               ║
    ║                                                              ║
    ║  MOUSE                                                       ║
    ║    Left click ... Move cursor & activate current tool       ║
    ║    Left drag .... Draw/erase continuously                   ║
    ║    Right click .. Eyedropper (pick color from cell)         ║
    ║    Middle click . Paste clipboard at position               ║
    ║    Scroll wheel . Move cursor up/down                       ║
    ║    Click palette  Select FG/BG color from status bar        ║
    ║    M ............. Toggle mouse on/off                       ║
    ║                                                              ║
    ║  OTHER                                                       ║
    ║    U / Ctrl+Z .... Undo                                     ║
    ║    R / Ctrl+Y .... Redo                                     ║
    ║    G ............. Toggle grid overlay                       ║
    ║    H / ? ......... This help screen                         ║
    ║    Q ............. Quit                                      ║
    ║                                                              ║
    ╚══════════════════════════════════════════════════════════════╝

    Press any key to return to the editor...
HELPEOF
    printf '\e[0m'
    IFS= read -rsn1
}

# ============================================================================
# Mouse handling
# ============================================================================
# Handle mouse action at canvas coordinates
handle_mouse_action() {
    local mx=$1 my=$2 btn=$3 event=$4  # event: press, release, drag, wheel_up, wheel_down

    # Check if click is on the color palette (status bar)
    local palette_row=$(( VIEWPORT_H + 2 ))  # After viewport + h-scrollbar
    if (( my == palette_row )); then
        handle_palette_click "$mx"
        return
    fi

    # Translate viewport coordinates to canvas coordinates
    mx=$(( mx + SCROLL_X ))
    my=$(( my + SCROLL_Y ))

    # Ignore clicks outside the canvas area
    if (( mx < 0 || mx >= CANVAS_W || my < 0 || my >= CANVAS_H )); then
        return
    fi

    case "$event" in
        press)
            if (( btn == 0 )); then
                # Left click - move cursor and activate tool
                CUR_X=$mx
                CUR_Y=$my
                case "$TOOL" in
                    draw)
                        MOUSE_DRAGGING=1
                        draw_at_cursor
                        ;;
                    fill)
                        flood_fill "$CUR_X" "$CUR_Y"
                        ;;
                    line)
                        if (( LINE_START_X < 0 )); then
                            LINE_START_X=$CUR_X
                            LINE_START_Y=$CUR_Y
                        else
                            draw_line "$LINE_START_X" "$LINE_START_Y" "$CUR_X" "$CUR_Y"
                            LINE_START_X=-1; LINE_START_Y=-1
                        fi
                        ;;
                    polyline)
                        if (( POLYLINE_LAST_X < 0 )); then
                            POLYLINE_LAST_X=$CUR_X
                            POLYLINE_LAST_Y=$CUR_Y
                        else
                            draw_line "$POLYLINE_LAST_X" "$POLYLINE_LAST_Y" "$CUR_X" "$CUR_Y"
                            POLYLINE_LAST_X=$CUR_X
                            POLYLINE_LAST_Y=$CUR_Y
                        fi
                        ;;
                    box)
                        if (( BOX_START_X < 0 )); then
                            BOX_START_X=$CUR_X
                            BOX_START_Y=$CUR_Y
                        else
                            draw_box "$BOX_START_X" "$BOX_START_Y" "$CUR_X" "$CUR_Y"
                            BOX_START_X=-1; BOX_START_Y=-1
                        fi
                        ;;
                    ellipse)
                        if (( ELLIPSE_START_X < 0 )); then
                            ELLIPSE_START_X=$CUR_X
                            ELLIPSE_START_Y=$CUR_Y
                        else
                            draw_ellipse "$ELLIPSE_START_X" "$ELLIPSE_START_Y" "$CUR_X" "$CUR_Y"
                            ELLIPSE_START_X=-1; ELLIPSE_START_Y=-1
                        fi
                        ;;
                    erase)
                        MOUSE_DRAGGING=1
                        erase_at_cursor
                        ;;
                    copy)
                        if (( ! SELECTING )); then
                            COPY_START_X=$CUR_X
                            COPY_START_Y=$CUR_Y
                            SELECTING=1
                        else
                            COPY_END_X=$CUR_X
                            COPY_END_Y=$CUR_Y
                            do_copy
                            SELECTING=0
                        fi
                        ;;
                esac
            elif (( btn == 2 )); then
                # Right click - eyedropper
                CUR_X=$mx
                CUR_Y=$my
                local idx=$(( CUR_X + CUR_Y * CANVAS_W ))
                CUR_FG=${CANVAS_FG[$idx]}
                CUR_BG=${CANVAS_BG[$idx]}
                CUR_BOLD=${CANVAS_BOLD[$idx]}
                CUR_BLINK=${CANVAS_BLINK[$idx]}
                local cell_ch="${CANVAS_CHAR[$idx]}"
                if [[ "$cell_ch" != " " ]]; then
                    CUR_CHAR="$cell_ch"
                fi
            elif (( btn == 1 )); then
                # Middle click - paste
                CUR_X=$mx
                CUR_Y=$my
                do_paste
            fi
            ;;
        drag)
            if (( btn == 0 && MOUSE_DRAGGING )); then
                CUR_X=$mx
                CUR_Y=$my
                case "$TOOL" in
                    draw)
                        # Draw without snapshotting every cell during drag
                        set_cell "$CUR_X" "$CUR_Y" "$CUR_CHAR" "$CUR_FG" "$CUR_BG" "$CUR_BOLD" "$CUR_BLINK"
                        ;;
                    erase)
                        set_cell "$CUR_X" "$CUR_Y" " " 7 0 0 0
                        ;;
                esac
            elif (( btn == 0 )); then
                # Move cursor during selection/line/box preview
                CUR_X=$mx
                CUR_Y=$my
            fi
            ;;
        release)
            MOUSE_DRAGGING=0
            ;;
        wheel_up)
            (( SCROLL_Y > 0 )) && (( SCROLL_Y -= 3 ))
            (( CUR_Y > 0 )) && (( CUR_Y -= 3 ))
            (( CUR_Y < 0 )) && CUR_Y=0
            clamp_scroll
            ;;
        wheel_down)
            (( SCROLL_Y += 3 ))
            (( CUR_Y += 3 ))
            (( CUR_Y >= CANVAS_H )) && CUR_Y=$(( CANVAS_H - 1 ))
            clamp_scroll
            ;;
    esac
}

# Handle clicks on the color palette in the status bar
handle_palette_click() {
    local mx=$1
    # FG palette starts at column 5, each color is 3 chars wide
    # " FG: " = 5 chars, then 16 colors * 3 = 48, then "  BG: " = 6 chars
    if (( mx >= 5 && mx < 53 )); then
        local color_idx=$(( (mx - 5) / 3 ))
        if (( color_idx >= 0 && color_idx < 16 )); then
            CUR_FG=$color_idx
        fi
    elif (( mx >= 59 && mx < 107 )); then
        local color_idx=$(( (mx - 59) / 3 ))
        if (( color_idx >= 0 && color_idx < 16 )); then
            CUR_BG=$color_idx
        fi
    fi
}

# ============================================================================
# Input handling
# ============================================================================
read_key() {
    local key
    IFS= read -rsn1 key

    if [[ "$key" == $'\e' ]]; then
        local seq=""
        IFS= read -rsn1 -t 0.1 seq
        if [[ -z "$seq" ]]; then
            echo "ESCAPE"
            return
        fi
        if [[ "$seq" == "[" ]]; then
            IFS= read -rsn1 -t 0.1 seq
            case "$seq" in
                '<')
                    # SGR mouse event: \e[<btn;col;row[Mm]
                    local mouse_seq=""
                    while IFS= read -rsn1 -t 0.1 mch; do
                        if [[ "$mch" == "M" || "$mch" == "m" ]]; then
                            # Parse: btn;col;row
                            IFS=';' read -r mbtn mcol mrow <<< "$mouse_seq"
                            local mx=$(( mcol - 1 ))  # 0-indexed
                            local my=$(( mrow - 1 ))
                            local base_btn=$(( mbtn & 3 ))
                            local is_drag=$(( (mbtn >> 5) & 1 ))
                            local is_wheel=$(( (mbtn >> 6) & 1 ))

                            if (( is_wheel )); then
                                if (( base_btn == 0 )); then
                                    echo "MOUSE_WHEEL_UP $mx $my"
                                else
                                    echo "MOUSE_WHEEL_DOWN $mx $my"
                                fi
                            elif [[ "$mch" == "m" ]]; then
                                echo "MOUSE_RELEASE $mx $my $base_btn"
                            elif (( is_drag )); then
                                echo "MOUSE_DRAG $mx $my $base_btn"
                            else
                                echo "MOUSE_PRESS $mx $my $base_btn"
                            fi
                            return
                        fi
                        mouse_seq+="$mch"
                    done
                    echo "UNKNOWN"
                    ;;
                A) echo "UP" ;;
                B) echo "DOWN" ;;
                C) echo "RIGHT" ;;
                D) echo "LEFT" ;;
                H) echo "HOME" ;;
                F) echo "END" ;;
                3) IFS= read -rsn1 -t 0.1; echo "DELETE" ;;
                5) IFS= read -rsn1 -t 0.1; echo "PGUP" ;;
                6) IFS= read -rsn1 -t 0.1; echo "PGDN" ;;
                Z) echo "SHIFT_TAB" ;;
                1)
                    IFS= read -rsn1 -t 0.1 seq
                    case "$seq" in
                        1) IFS= read -rsn1 -t 0.1; echo "F1" ;;
                        2) IFS= read -rsn1 -t 0.1; echo "F2" ;;
                        3) IFS= read -rsn1 -t 0.1; echo "F3" ;;
                        4) IFS= read -rsn1 -t 0.1; echo "F4" ;;
                        5) IFS= read -rsn1 -t 0.1; echo "F5" ;;
                        ~) echo "HOME" ;;
                        *) echo "UNKNOWN" ;;
                    esac
                    ;;
                *) echo "UNKNOWN" ;;
            esac
        elif [[ "$seq" == "O" ]]; then
            IFS= read -rsn1 -t 0.1 seq
            case "$seq" in
                P) echo "F1" ;;
                Q) echo "F2" ;;
                R) echo "F3" ;;
                S) echo "F4" ;;
                H) echo "HOME" ;;
                F) echo "END" ;;
                *) echo "UNKNOWN" ;;
            esac
        fi
    elif [[ "$key" == $'\t' ]]; then
        echo "TAB"
    elif [[ "$key" == " " ]]; then
        echo "SPACE"
    elif [[ "$key" == $'\n' || "$key" == "" ]]; then
        echo "ENTER"
    elif [[ "$key" == $'\177' || "$key" == $'\b' ]]; then
        echo "BACKSPACE"
    elif [[ "$key" == $'\x13' ]]; then  # Ctrl+S
        echo "CTRL_S"
    elif [[ "$key" == $'\x0f' ]]; then  # Ctrl+O
        echo "CTRL_O"
    elif [[ "$key" == $'\x0e' ]]; then  # Ctrl+N
        echo "CTRL_N"
    elif [[ "$key" == $'\x1a' ]]; then  # Ctrl+Z
        echo "CTRL_Z"
    elif [[ "$key" == $'\x19' ]]; then  # Ctrl+Y
        echo "CTRL_Y"
    else
        echo "$key"
    fi
}

handle_input() {
    local key
    key=$(read_key)

    # Handle mouse events first
    case "$key" in
        MOUSE_PRESS*)
            read -r _ mx my btn <<< "$key"
            handle_mouse_action "$mx" "$my" "$btn" "press"
            return
            ;;
        MOUSE_RELEASE*)
            read -r _ mx my btn <<< "$key"
            handle_mouse_action "$mx" "$my" "$btn" "release"
            return
            ;;
        MOUSE_DRAG*)
            read -r _ mx my btn <<< "$key"
            handle_mouse_action "$mx" "$my" "$btn" "drag"
            return
            ;;
        MOUSE_WHEEL_UP*)
            read -r _ mx my <<< "$key"
            handle_mouse_action "$mx" "$my" 0 "wheel_up"
            return
            ;;
        MOUSE_WHEEL_DOWN*)
            read -r _ mx my <<< "$key"
            handle_mouse_action "$mx" "$my" 0 "wheel_down"
            return
            ;;
    esac

    case "$key" in
        UP)
            (( CUR_Y > 0 )) && (( CUR_Y-- ))
            ;;
        DOWN)
            (( CUR_Y < CANVAS_H - 1 )) && (( CUR_Y++ ))
            ;;
        LEFT)
            (( CUR_X > 0 )) && (( CUR_X-- ))
            ;;
        RIGHT)
            (( CUR_X < CANVAS_W - 1 )) && (( CUR_X++ ))
            ;;
        HOME)
            CUR_X=0
            ;;
        END)
            CUR_X=$(( CANVAS_W - 1 ))
            ;;
        PGUP)
            (( CUR_Y -= VIEWPORT_H ))
            (( CUR_Y < 0 )) && CUR_Y=0
            ;;
        PGDN)
            (( CUR_Y += VIEWPORT_H ))
            (( CUR_Y >= CANVAS_H )) && CUR_Y=$(( CANVAS_H - 1 ))
            ;;
        SPACE|ENTER)
            case "$TOOL" in
                draw)
                    draw_at_cursor
                    ;;
                fill)
                    flood_fill "$CUR_X" "$CUR_Y"
                    ;;
                line)
                    if (( LINE_START_X < 0 )); then
                        LINE_START_X=$CUR_X
                        LINE_START_Y=$CUR_Y
                    else
                        draw_line "$LINE_START_X" "$LINE_START_Y" "$CUR_X" "$CUR_Y"
                        LINE_START_X=-1
                        LINE_START_Y=-1
                    fi
                    ;;
                polyline)
                    if (( POLYLINE_LAST_X < 0 )); then
                        # First click sets starting point
                        POLYLINE_LAST_X=$CUR_X
                        POLYLINE_LAST_Y=$CUR_Y
                    else
                        # Draw from last point to current, then chain
                        draw_line "$POLYLINE_LAST_X" "$POLYLINE_LAST_Y" "$CUR_X" "$CUR_Y"
                        POLYLINE_LAST_X=$CUR_X
                        POLYLINE_LAST_Y=$CUR_Y
                    fi
                    ;;
                box)
                    if (( BOX_START_X < 0 )); then
                        BOX_START_X=$CUR_X
                        BOX_START_Y=$CUR_Y
                    else
                        draw_box "$BOX_START_X" "$BOX_START_Y" "$CUR_X" "$CUR_Y"
                        BOX_START_X=-1
                        BOX_START_Y=-1
                    fi
                    ;;
                ellipse)
                    if (( ELLIPSE_START_X < 0 )); then
                        ELLIPSE_START_X=$CUR_X
                        ELLIPSE_START_Y=$CUR_Y
                    else
                        draw_ellipse "$ELLIPSE_START_X" "$ELLIPSE_START_Y" "$CUR_X" "$CUR_Y"
                        ELLIPSE_START_X=-1
                        ELLIPSE_START_Y=-1
                    fi
                    ;;
                erase)
                    erase_at_cursor
                    ;;
                copy)
                    if (( ! SELECTING )); then
                        COPY_START_X=$CUR_X
                        COPY_START_Y=$CUR_Y
                        SELECTING=1
                    else
                        COPY_END_X=$CUR_X
                        COPY_END_Y=$CUR_Y
                        do_copy
                        SELECTING=0
                    fi
                    ;;
            esac
            ;;
        TAB)
            (( DRAW_CHAR_IDX = (DRAW_CHAR_IDX + 1) % ${#DRAW_CHARS[@]} ))
            CUR_CHAR="${DRAW_CHARS[$DRAW_CHAR_IDX]}"
            ;;
        SHIFT_TAB)
            (( DRAW_CHAR_IDX = (DRAW_CHAR_IDX - 1 + ${#DRAW_CHARS[@]}) % ${#DRAW_CHARS[@]} ))
            CUR_CHAR="${DRAW_CHARS[$DRAW_CHAR_IDX]}"
            ;;
        DELETE)
            erase_at_cursor
            ;;
        BACKSPACE)
            erase_at_cursor
            (( CUR_X > 0 )) && (( CUR_X-- ))
            ;;
        1|F1) color_picker "fg" ;;
        2|F2) color_picker "bg" ;;
        3|F3) char_picker ;;
        4|F4) CUR_BOLD=$(( 1 - CUR_BOLD )) ;;
        5|F5) CUR_BLINK=$(( 1 - CUR_BLINK )) ;;
        [sS]|CTRL_S)
            local fname
            if fname=$(prompt_filename "Save as" "$FILENAME"); then
                save_file "$fname"
            fi
            ;;
        [oO]|CTRL_O)
            local fname
            if fname=$(prompt_filename "Open file" "$FILENAME"); then
                if [[ -f "$fname" ]]; then
                    load_file "$fname"
                fi
            fi
            ;;
        [nN]|CTRL_N)
            init_canvas
            FILENAME="untitled.ans"
            CUR_X=0; CUR_Y=0
            ;;
        [uU]|CTRL_Z) do_undo ;;
        [rR]|CTRL_Y) do_redo ;;
        [fF])
            TOOL="fill"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            ;;
        [lL])
            TOOL="line"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            ;;
        [kK])
            TOOL="polyline"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            ;;
        [bB])
            TOOL="box"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            ;;
        [iI])
            TOOL="ellipse"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            ;;
        [eE])
            TOOL="erase"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            ;;
        [cC])
            TOOL="copy"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            COPY_START_X=-1; COPY_END_X=-1
            ;;
        [vV])
            do_paste
            ;;
        [dD])
            TOOL="draw"
            LINE_START_X=-1; BOX_START_X=-1; ELLIPSE_START_X=-1; POLYLINE_LAST_X=-1; POLYLINE_LAST_Y=-1; SELECTING=0
            ;;
        [pP])
            # Eyedropper - pick color from current cell
            local idx=$(( CUR_X + CUR_Y * CANVAS_W ))
            CUR_FG=${CANVAS_FG[$idx]}
            CUR_BG=${CANVAS_BG[$idx]}
            CUR_BOLD=${CANVAS_BOLD[$idx]}
            CUR_BLINK=${CANVAS_BLINK[$idx]}
            local cell_ch="${CANVAS_CHAR[$idx]}"
            if [[ "$cell_ch" != " " ]]; then
                CUR_CHAR="$cell_ch"
            fi
            ;;
        [gG])
            GRID_ON=$(( 1 - GRID_ON ))
            ;;
        [mM])
            MOUSE_ON=$(( 1 - MOUSE_ON ))
            if (( MOUSE_ON )); then
                enable_mouse
            else
                disable_mouse
            fi
            ;;
        "+"|"=")
            # Increase canvas size by 10 in each dimension (max 1000)
            resize_canvas $(( CANVAS_W + 10 )) $(( CANVAS_H + 10 ))
            ;;
        "-"|"_")
            # Decrease canvas size by 10 (min 20x10)
            resize_canvas $(( CANVAS_W - 10 )) $(( CANVAS_H - 10 ))
            ;;
        [hH]|"?")
            show_help
            ;;
        [qQ])
            if (( MODIFIED )); then
                local row=$(( VIEWPORT_H + 2 ))
                printf "\e[${row};1H\e[0;97;41m"
                printf " Unsaved changes! Press Q again to quit, any other key to cancel. "
                printf "%*s\e[0m" 20 ""
                IFS= read -rsn1 confirm
                if [[ "$confirm" == "q" || "$confirm" == "Q" ]]; then
                    restore_terminal
                    exit 0
                fi
            else
                restore_terminal
                exit 0
            fi
            ;;
        # Direct character input for drawing (printable ASCII that isn't a command)
        *)
            if [[ ${#key} -eq 1 ]] && [[ "$key" =~ [^a-zA-Z0-9] ]]; then
                CUR_CHAR="$key"
                draw_at_cursor
            fi
            ;;
    esac
}

# ============================================================================
# Main
# ============================================================================
main() {
    # Handle arguments
    if [[ $# -gt 0 ]]; then
        FILENAME="$1"
    fi

    setup_terminal
    trap restore_terminal EXIT INT TERM

    init_canvas

    # Load file if specified and exists
    if [[ -f "$FILENAME" ]]; then
        load_file "$FILENAME"
    fi

    # Main loop
    while true; do
        render_all
        handle_input
    done
}

main "$@"
