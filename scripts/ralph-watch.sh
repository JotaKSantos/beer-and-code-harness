#!/usr/bin/env bash
#
# ralph-watch.sh
#
# Painel de acompanhamento do ralph.sh em tempo real.
#
# Le o estado publicado pelo ralph em .phases/state/ e redesenha o painel.
# Nao executa nada, nao escreve no estado: e um leitor puro. Pode rodar num
# segundo terminal enquanto o ralph trabalha, ou ser embutido pelo proprio
# ralph via `ralph.sh --dashboard`.
#
# Uso:
#   ./ralph-watch.sh [opcoes] [caminho-do-repo]
#
# Opcoes:
#   --once              desenha um frame e sai (util em script/teste)
#   --interval N        segundos entre frames (default: 1)
#   --embedded          modo chamado pelo ralph: nao troca a tela alternativa
#                       (quem chamou ja trocou) e sai quando o run termina
#   --no-color          desliga ANSI
#
# Contrato de estado (escrito pelo ralph, TSV, um escritor por arquivo):
#
#   .phases/state/run.tsv      escritor: processo principal do ralph
#     META<TAB>chave<TAB>valor
#     PHASE<TAB>num<TAB>status<TAB>tentativa<TAB>"g0 g1 g2 g3"<TAB>titulo
#     TASK<TAB>fase<TAB>indice<TAB>status<TAB>titulo
#
#   .phases/state/live.tsv     escritor: watcher do stream da sessao corrente
#     PHASE<TAB>num
#     ACTIVITY<TAB>texto
#     LIVE<TAB>indice<TAB>status
#
# Dois arquivos com um escritor cada evitam corrida entre o loop principal e o
# watcher do stream, que roda em subprocesso. O merge acontece aqui, na leitura:
# live.tsv tem precedencia sobre run.tsv para as tasks da fase corrente.
#
# Vocabulario de status:
#   fase  pending | running | done | failed | skipped
#   task  pending | running | done | incomplete
#   gate  pending | run | pass | fail | skip

set -uo pipefail

REPO="."
ONCE=false
EMBEDDED=false
INTERVAL=1
USE_COLOR=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --once)       ONCE=true; shift ;;
    --embedded)   EMBEDDED=true; shift ;;
    --interval)   INTERVAL="$2"; shift 2 ;;
    --interval=*) INTERVAL="${1#*=}"; shift ;;
    --no-color)   USE_COLOR=false; shift ;;
    -h|--help)    sed -n '2,40p' "$0"; exit 0 ;;
    *)            REPO="$1"; shift ;;
  esac
done

[ -t 1 ] || USE_COLOR=false

STATE_DIR="$REPO/.phases/state"
RUN_STATE="$STATE_DIR/run.tsv"
LIVE_STATE="$STATE_DIR/live.tsv"

# ---------------------------------------------------------------------------
# Cores
# ---------------------------------------------------------------------------

if $USE_COLOR; then
  C_RESET=$'\033[0m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
  C_CYAN=$'\033[38;5;81m'; C_GREEN=$'\033[38;5;77m'; C_YELLOW=$'\033[38;5;221m'
  C_RED=$'\033[38;5;203m'; C_GREY=$'\033[38;5;245m'; C_WHITE=$'\033[38;5;255m'
  C_HILITE=$'\033[48;5;53m'
else
  C_RESET=""; C_DIM=""; C_BOLD=""
  C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_GREY=""; C_WHITE=""
  C_HILITE=""
fi

# ---------------------------------------------------------------------------
# Estado lido
# ---------------------------------------------------------------------------

declare -A META PH_STATUS PH_ATTEMPT PH_GATES PH_TITLE
declare -A TK_STATUS TK_TITLE TK_COUNT
declare -a PHASE_NUMS
LIVE_PHASE=""

reset_state() {
  META=(); PH_STATUS=(); PH_ATTEMPT=(); PH_GATES=(); PH_TITLE=()
  TK_STATUS=(); TK_TITLE=(); TK_COUNT=()
  PHASE_NUMS=()
  LIVE_PHASE=""
}

read_state() {
  reset_state
  [ -f "$RUN_STATE" ] || return 1

  local kind a b c d e
  while IFS=$'\t' read -r kind a b c d e; do
    case "$kind" in
      META)  META[$a]="$b" ;;
      PHASE)
        PHASE_NUMS+=("$a")
        PH_STATUS[$a]="$b"; PH_ATTEMPT[$a]="$c"; PH_GATES[$a]="$d"; PH_TITLE[$a]="$e"
        TK_COUNT[$a]="${TK_COUNT[$a]:-0}"
        ;;
      TASK)
        TK_STATUS[$a:$b]="$c"; TK_TITLE[$a:$b]="$d"
        TK_COUNT[$a]="$b"
        ;;
    esac
  done < "$RUN_STATE"

  # live.tsv vence para a fase corrente: e o que a sessao esta fazendo agora.
  if [ -f "$LIVE_STATE" ]; then
    while IFS=$'\t' read -r kind a b c; do
      case "$kind" in
        PHASE)    LIVE_PHASE="$a" ;;
        ACTIVITY) [ -n "$a" ] && META[activity]="$a" ;;
        LIVE)
          if [ -n "$LIVE_PHASE" ] && [ -n "${TK_STATUS[$LIVE_PHASE:$a]+x}" ]; then
            # nao rebaixa uma task ja confirmada pelo verificador (gate 3)
            case "${TK_STATUS[$LIVE_PHASE:$a]}" in
              done|incomplete) ;;
              *) TK_STATUS[$LIVE_PHASE:$a]="$b" ;;
            esac
          fi
          ;;
      esac
    done < "$LIVE_STATE"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Primitivas de desenho
# ---------------------------------------------------------------------------

# pad <texto> <largura> — trunca com reticencia ou completa com espacos.
# Em locale UTF-8 ${#s} conta caracteres, nao bytes: e o que mantem o
# alinhamento das colunas com acentos e box-drawing.
pad() {
  local s="$1" w="$2" n
  n=${#s}
  if [ "$n" -gt "$w" ]; then
    if [ "$w" -gt 1 ]; then s="${s:0:w-1}…"; else s="${s:0:w}"; fi
    n=$w
  fi
  printf '%s%*s' "$s" $((w - n)) ''
}

repeat() { local ch="$1" n="$2" out="" i; for ((i=0; i<n; i++)); do out+="$ch"; done; printf '%s' "$out"; }

bar() {
  local done_n="$1" total="$2" width="$3"
  local filled=0
  [ "$total" -gt 0 ] && filled=$(( done_n * width / total ))
  [ "$filled" -gt "$width" ] && filled=$width
  printf '%s%s%s%s%s' \
    "$C_GREEN" "$(repeat '█' "$filled")" "$C_GREY" "$(repeat '░' $((width - filled)))" "$C_RESET"
}

pct() {
  local n="$1" total="$2"
  [ "$total" -gt 0 ] || { printf '0%%'; return; }
  printf '%d%%' $(( n * 100 / total ))
}

fmt_duration() {
  local t="$1" h m s
  h=$((t / 3600)); m=$(((t % 3600) / 60)); s=$((t % 60))
  if [ "$h" -gt 0 ]; then printf '%dh %02dm %02ds' "$h" "$m" "$s"
  elif [ "$m" -gt 0 ]; then printf '%dm %02ds' "$m" "$s"
  else printf '%ds' "$s"; fi
}

# ---------------------------------------------------------------------------
# Vocabulario -> rotulo colorido
# ---------------------------------------------------------------------------

status_label() {
  case "$1" in
    done)       printf '%s✓ Concluída%s'   "$C_GREEN"  "$C_RESET" ;;
    running)    printf '%s▶ Em execução%s' "$C_YELLOW" "$C_RESET" ;;
    failed)     printf '%s✗ Falhou%s'      "$C_RED"    "$C_RESET" ;;
    incomplete) printf '%s! Incompleta%s'  "$C_RED"    "$C_RESET" ;;
    skipped)    printf '%s– Pulada%s'      "$C_GREY"   "$C_RESET" ;;
    *)          printf '%s· Pendente%s'    "$C_GREY"   "$C_RESET" ;;
  esac
}

status_plain() {
  case "$1" in
    done)       printf '✓ Concluída' ;;
    running)    printf '▶ Em execução' ;;
    failed)     printf '✗ Falhou' ;;
    incomplete) printf '! Incompleta' ;;
    skipped)    printf '– Pulada' ;;
    *)          printf '· Pendente' ;;
  esac
}

gate_mark() {
  case "$1" in
    pass) printf '%s✓%s' "$C_GREEN"  "$C_RESET" ;;
    fail) printf '%s✗%s' "$C_RED"    "$C_RESET" ;;
    run)  printf '%s⋯%s' "$C_YELLOW" "$C_RESET" ;;
    skip) printf '%s⊘%s' "$C_GREY"   "$C_RESET" ;;
    *)    printf '%s·%s' "$C_GREY"   "$C_RESET" ;;
  esac
}

gate_mark_plain() {
  case "$1" in
    pass) printf '✓' ;; fail) printf '✗' ;; run) printf '⋯' ;;
    skip) printf '⊘' ;; *) printf '·' ;;
  esac
}

gates_cell() {
  local spec="$1" colored="$2"
  local -a g
  read -r -a g <<< "$spec"
  local i out=""
  for i in 0 1 2 3; do
    [ "$i" -gt 0 ] && out+=" "
    if [ "$colored" = "1" ]; then
      out+="${C_GREY}G$i${C_RESET} $(gate_mark "${g[$i]:-pending}")"
    else
      out+="G$i $(gate_mark_plain "${g[$i]:-pending}")"
    fi
  done
  printf '%s' "$out"
}

# ---------------------------------------------------------------------------
# Frame
# ---------------------------------------------------------------------------

W=100

# RALPH_WATCH_COLS fixa a largura (teste, pipe, terminal que nao reporta).
#
# `tput cols` sozinho nao basta: com --embedded o painel roda em background
# (`&`) a partir do ralph, e ali o tput pode nao enxergar o terminal — o painel
# caia para a largura minima e truncava os titulos num terminal largo.
# /dev/tty responde mesmo em background, entao serve de segunda fonte.
calc_width() {
  local cols="${RALPH_WATCH_COLS:-}"

  # stty PRIMEIRO: le o tamanho real do terminal por ioctl. `tput cols` parece
  # funcionar mas devolve o 80 do terminfo quando nao consegue determinar o
  # tamanho — e 80 e um numero plausivel, entao passava batido e o painel
  # ficava com metade da largura num terminal largo.
  if ! [[ "$cols" =~ ^[0-9]+$ ]]; then
    cols=$(stty size < /dev/tty 2>/dev/null | cut -d' ' -f2 || true)
  fi
  if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -lt 40 ]; then
    cols=$(tput cols 2>/dev/null || true)
  fi
  if ! [[ "$cols" =~ ^[0-9]+$ ]] || [ "$cols" -lt 40 ]; then
    cols="${COLUMNS:-}"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=100

  # Sem teto artificial: o painel acompanha o terminal. calc_width roda a cada
  # frame, entao redimensionar a janela reflete no desenho seguinte.
  W=$cols
  [ "$W" -lt 64 ] && W=64
}

box_top() {
  local w="$1" title="$2" pre
  pre=$(( (w - ${#title} - 2) / 2 ))
  printf '%s┌%s %s %s┐%s\n' \
    "$C_CYAN" "$(repeat '─' "$pre")" "$title" \
    "$(repeat '─' $(( w - pre - ${#title} - 2 )))" "$C_RESET"
}

box_bottom() { printf '%s└%s┘%s\n' "$C_CYAN" "$(repeat '─' "$1")" "$C_RESET"; }

phase_counts() {
  local num
  PH_DONE=0; PH_TOTAL=0
  for num in "${PHASE_NUMS[@]}"; do
    PH_TOTAL=$((PH_TOTAL + 1))
    case "${PH_STATUS[$num]}" in done|skipped) PH_DONE=$((PH_DONE + 1)) ;; esac
  done
}

# Todas as tasks do run, nao so as da fase corrente: a barra mede o progresso
# do trabalho inteiro, do mesmo jeito que a de fases.
task_counts() {
  local num i
  TK_DONE=0; TK_TOTAL=0
  for num in "${PHASE_NUMS[@]}"; do
    for ((i=1; i<=${TK_COUNT[$num]:-0}; i++)); do
      TK_TOTAL=$((TK_TOTAL + 1))
      [ "${TK_STATUS[$num:$i]:-pending}" = "done" ] && TK_DONE=$((TK_DONE + 1))
    done
  done
}

run_status_label() {
  case "${META[status]:-running}" in
    running)  printf '%s▶ Em execução%s' "$C_YELLOW" "$C_RESET" ;;
    waiting)  printf '%s⏸ Aguardando reset de limite%s' "$C_YELLOW" "$C_RESET" ;;
    finished) printf '%s✓ Concluído%s' "$C_GREEN" "$C_RESET" ;;
    failed)   printf '%s✗ Falhou%s' "$C_RED" "$C_RESET" ;;
    *)        printf '%s· %s%s' "$C_GREY" "${META[status]:-?}" "$C_RESET" ;;
  esac
}

run_status_plain() {
  case "${META[status]:-running}" in
    running)  printf '▶ Em execução' ;;
    waiting)  printf '⏸ Aguardando reset de limite' ;;
    finished) printf '✓ Concluído' ;;
    failed)   printf '✗ Falhou' ;;
    *)        printf '· %s' "${META[status]:-?}" ;;
  esac
}

draw_header() {
  local now elapsed
  now=$(date +%s)
  elapsed=$(( now - ${META[started]:-$now} ))
  [ "${META[status]:-running}" != "running" ] && [ -n "${META[ended]:-}" ] \
    && elapsed=$(( ${META[ended]} - ${META[started]:-$now} ))

  printf '\n%s%sRALPH%s\n\n' "$C_BOLD" "$C_CYAN" "$C_RESET"

  local col=$(( (W - 4) / 3 ))
  printf '%sProjeto:%s %s  %sEngine:%s %s  %sStatus:%s %s\n' \
    "$C_CYAN" "$C_RESET" "$(pad "${META[project]:-?}" $((col - 10)))" \
    "$C_CYAN" "$C_RESET" "$(pad "${META[engine]:-?}" $((col - 9)))" \
    "$C_CYAN" "$C_RESET" "$(run_status_label)"
  printf '%sDuração:%s %s  %sRun:%s %s  %sPID:%s %s\n\n' \
    "$C_CYAN" "$C_RESET" "$(pad "$(fmt_duration "$elapsed")" $((col - 10)))" \
    "$C_CYAN" "$C_RESET" "$(pad "${META[run]:-?}" $((col - 6)))" \
    "$C_CYAN" "$C_RESET" "${META[pid]:-?}"
}

draw_panels() {
  phase_counts
  task_counts

  local lw=$(( (W - 1) / 2 )) rw
  rw=$(( W - lw - 2 ))
  local li=$(( lw - 2 )) ri=$(( rw - 2 ))

  local -a L=() R=() LP=() RP=()
  local bw=$(( li - 26 ))
  [ "$bw" -lt 8 ] && bw=8

  local l1 l2
  l1=$(printf 'Fases  %s  [%s]  %s' "$(pad "$PH_DONE/$PH_TOTAL" 7)" "$(bar "$PH_DONE" "$PH_TOTAL" "$bw")" "$(pct "$PH_DONE" "$PH_TOTAL")")
  l2=$(printf 'Tasks  %s  [%s]  %s' "$(pad "$TK_DONE/$TK_TOTAL" 7)" "$(bar "$TK_DONE" "$TK_TOTAL" "$bw")" "$(pct "$TK_DONE" "$TK_TOTAL")")
  L+=("$l1"); LP+=("$(printf 'Fases  %s  [%s]  %s' "$(pad "$PH_DONE/$PH_TOTAL" 7)" "$(repeat ' ' "$bw")" "$(pct "$PH_DONE" "$PH_TOTAL")")")
  L+=("$l2"); LP+=("$(printf 'Tasks  %s  [%s]  %s' "$(pad "$TK_DONE/$TK_TOTAL" 7)" "$(repeat ' ' "$bw")" "$(pct "$TK_DONE" "$TK_TOTAL")")")
  L+=(""); LP+=("")
  L+=("$(printf '%sTeste:%s %s' "$C_GREY" "$C_RESET" "${META[test_cmd]:-—}")")
  LP+=("$(printf 'Teste: %s' "${META[test_cmd]:-—}")")

  local cur="${META[phase_cur]:-}"
  local fase_txt="—"
  [ -n "$cur" ] && fase_txt="$cur · ${PH_TITLE[$cur]:-}"

  R+=("$(printf '%sFase:%s      %s' "$C_CYAN" "$C_RESET" "$fase_txt")")
  RP+=("$(printf 'Fase:      %s' "$fase_txt")")
  R+=("$(printf '%sCiclo:%s     %s    %sGate:%s %s' "$C_CYAN" "$C_RESET" "${META[cycle]:-—}/${META[cycle_max]:-—}" "$C_CYAN" "$C_RESET" "${META[gate]:-—}")")
  RP+=("$(printf 'Ciclo:     %s    Gate: %s' "${META[cycle]:-—}/${META[cycle_max]:-—}" "${META[gate]:-—}")")
  R+=("$(printf '%sAtividade:%s %s' "$C_CYAN" "$C_RESET" "${META[activity]:-—}")")
  RP+=("$(printf 'Atividade: %s' "${META[activity]:-—}")")
  R+=("$(printf '%sÚltimo erro:%s %s%s%s' "$C_CYAN" "$C_RESET" "$C_RED" "${META[last_error]:-—}" "$C_RESET")")
  RP+=("$(printf 'Último erro: %s' "${META[last_error]:-—}")")

  # Cabecalhos e rodapes dos dois boxes, lado a lado
  local top_l top_r bot_l bot_r
  top_l=$(box_top "$li" "PROGRESSO"); top_r=$(box_top "$ri" "TRABALHO ATUAL")
  bot_l=$(box_bottom "$li");          bot_r=$(box_bottom "$ri")
  printf '%s %s\n' "$top_l" "$top_r"

  local i n=${#L[@]}
  [ "${#R[@]}" -gt "$n" ] && n=${#R[@]}
  for ((i=0; i<n; i++)); do
    local lc="${L[$i]:-}" lp="${LP[$i]:-}" rc="${R[$i]:-}" rp="${RP[$i]:-}"
    # trunca pelo texto sem cor e reaplica o conteudo colorido
    if [ "${#lp}" -gt $(( li - 2 )) ]; then lc=$(pad "$lp" $(( li - 2 ))); lp="$lc"; fi
    if [ "${#rp}" -gt $(( ri - 2 )) ]; then rc=$(pad "$rp" $(( ri - 2 ))); rp="$rc"; fi
    printf '%s│%s %s%*s %s│%s %s│%s %s%*s %s│%s\n' \
      "$C_CYAN" "$C_RESET" "$lc" $(( li - 2 - ${#lp} )) '' "$C_CYAN" "$C_RESET" \
      "$C_CYAN" "$C_RESET" "$rc" $(( ri - 2 - ${#rp} )) '' "$C_CYAN" "$C_RESET"
  done
  printf '%s %s\n' "$bot_l" "$bot_r"
}

draw_table() {
  # c_gates=19 cabe "G0 ✓ G1 ✓ G2 ✓ G3 ✓" inteiro; c_status=14 cabe o rotulo
  # mais longo ("▶ Em execução"). Encolher qualquer um deles corta a informacao.
  local c_id=4 c_status=14 c_try=9 c_gates=19
  local c_name=$(( W - c_id - c_status - c_try - c_gates - 16 ))
  [ "$c_name" -lt 16 ] && c_name=16

  local sep_t sep_m sep_b
  sep_t=$(printf '%s┌%s┬%s┬%s┬%s┬%s┐%s' "$C_CYAN" \
    "$(repeat '─' $((c_id+2)))" "$(repeat '─' $((c_name+2)))" "$(repeat '─' $((c_status+2)))" \
    "$(repeat '─' $((c_try+2)))" "$(repeat '─' $((c_gates+2)))" "$C_RESET")
  sep_m=$(printf '%s├%s┼%s┼%s┼%s┼%s┤%s' "$C_CYAN" \
    "$(repeat '─' $((c_id+2)))" "$(repeat '─' $((c_name+2)))" "$(repeat '─' $((c_status+2)))" \
    "$(repeat '─' $((c_try+2)))" "$(repeat '─' $((c_gates+2)))" "$C_RESET")
  sep_b=$(printf '%s└%s┴%s┴%s┴%s┴%s┘%s' "$C_CYAN" \
    "$(repeat '─' $((c_id+2)))" "$(repeat '─' $((c_name+2)))" "$(repeat '─' $((c_status+2)))" \
    "$(repeat '─' $((c_try+2)))" "$(repeat '─' $((c_gates+2)))" "$C_RESET")

  local V="${C_CYAN}│${C_RESET}"

  printf '%s\n' "$sep_t"
  printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$V" \
    "${C_CYAN}$(pad 'ID' $c_id)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Fase / Task' $c_name)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Status' $c_status)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Tentativa' $c_try)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Gates' $c_gates)${C_RESET}" "$V"
  printf '%s\n' "$sep_m"

  # Celula colorida com padding correto: mede o texto SEM ANSI (plain) e
  # completa a diferenca. Colorir depois de padear inflaria a largura visivel.
  cell() { # <colorido> <plain> <largura>
    local colored="$1" plain="$2" w="$3" n=${#2}
    if [ "$n" -gt "$w" ]; then printf '%s' "$(pad "$plain" "$w")"; return; fi
    printf '%s%*s' "$colored" $(( w - n )) ''
  }

  local num i st tries hl row
  for num in "${PHASE_NUMS[@]}"; do
    st="${PH_STATUS[$num]}"
    tries="${PH_ATTEMPT[$num]}"
    [ "$tries" = "0" ] && tries="–"
    hl=""
    [ "$st" = "running" ] && hl="$C_HILITE"

    row=$(printf '%s %s %s %s %s %s %s %s %s %s %s' "$V" \
      "$(pad "F$num" $c_id)" "$V" \
      "$(cell "${C_WHITE}$(pad "${PH_TITLE[$num]}" $c_name)${C_RESET}" "$(pad "${PH_TITLE[$num]}" $c_name)" $c_name)" "$V" \
      "$(cell "$(status_label "$st")" "$(status_plain "$st")" $c_status)" "$V" \
      "$(pad "$tries" $c_try)" "$V" \
      "$(cell "$(gates_cell "${PH_GATES[$num]}" 1)" "$(gates_cell "${PH_GATES[$num]}" 0)" $c_gates)" "$V")
    printf '%s%s%s\n' "$hl" "$row" "$C_RESET"

    local tst thl ttitle
    for ((i=1; i<=${TK_COUNT[$num]:-0}; i++)); do
      tst="${TK_STATUS[$num:$i]:-pending}"
      thl=""
      [ "$tst" = "running" ] && thl="$C_HILITE"
      ttitle=$(pad "  ↳ ${TK_TITLE[$num:$i]}" $c_name)
      row=$(printf '%s %s %s %s %s %s %s %s %s %s %s' "$V" \
        "$(cell "${C_GREY}$(pad "T$i" $c_id)${C_RESET}" "$(pad "T$i" $c_id)" $c_id)" "$V" \
        "$ttitle" "$V" \
        "$(cell "$(status_label "$tst")" "$(status_plain "$tst")" $c_status)" "$V" \
        "$(cell "${C_GREY}$(pad '–' $c_try)${C_RESET}" "$(pad '–' $c_try)" $c_try)" "$V" \
        "$(cell "${C_GREY}$(pad '–' $c_gates)${C_RESET}" "$(pad '–' $c_gates)" $c_gates)" "$V")
      printf '%s%s%s\n' "$thl" "$row" "$C_RESET"
    done
  done
  printf '%s\n' "$sep_b"
}

draw() {
  calc_width
  draw_header
  draw_panels
  draw_table
  if [ -n "${META[note]:-}" ]; then
    printf '\n%s%s%s\n' "$C_YELLOW" "${META[note]}" "$C_RESET"
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

cleanup() {
  $EMBEDDED || { $ONCE || tput rmcup 2>/dev/null; }
  tput cnorm 2>/dev/null || true
}

main() {
  if ! $ONCE && ! $EMBEDDED; then
    tput smcup 2>/dev/null || true
    trap cleanup EXIT INT TERM
    tput civis 2>/dev/null || true
  elif $EMBEDDED; then
    trap 'tput cnorm 2>/dev/null || true' EXIT INT TERM
    tput civis 2>/dev/null || true
  fi

  if $ONCE; then
    if ! read_state; then
      echo "Nenhum estado em $RUN_STATE — o ralph ja rodou neste repo?" >&2
      exit 1
    fi
    draw
    exit 0
  fi

  local frame
  while true; do
    if read_state; then
      frame=$(draw)
      printf '\033[H%s\033[J' "$frame"
      case "${META[status]:-running}" in
        finished|failed)
          $EMBEDDED && break
          ;;
      esac
    else
      printf '\033[H%sAguardando o ralph iniciar (%s)…%s\033[J\n' "$C_GREY" "$RUN_STATE" "$C_RESET"
    fi
    sleep "$INTERVAL"
  done
}

main
