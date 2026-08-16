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
# Layout: o topo (identificacao, barras, trabalho atual) e fixo; a tabela de
# fases e tasks rola dentro de uma janela que cabe na altura do terminal. Sem
# isso, num plano com dezenas de tasks o cabecalho subia para fora da tela
# alternativa — onde o scroll do terminal nao alcanca.
#
# Teclas (quando ha /dev/tty, inclusive rodando embutido no ralph):
#   ↑/↓ ou k/j     rola uma linha        PgUp/PgDn ou b/espaco  rola uma pagina
#   Home/g         primeira linha        End/G                  ultima linha
#   f              volta a seguir a fase corrente (modo automatico)
#   q              sai do painel (nao interrompe o ralph)
#
# Variaveis de ambiente:
#   RALPH_WATCH_COLS   fixa a largura (teste, pipe, terminal que nao reporta)
#   RALPH_WATCH_LINES  fixa a altura; com --once tambem liga a janela rolante
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
    -h|--help)    sed -n '2,56p' "$0"; exit 0 ;;
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
H=24

# Estado da janela rolante da tabela. FOLLOW=true deixa o painel escolher o
# recorte sozinho (segue a fase corrente); qualquer tecla de rolagem passa o
# controle para o usuario ate ele apertar `f`.
OFF=0
FOLLOW=true
QUIT=false
VIS=0
TOTAL=0
MAX_OFF=0
FOOTER=0
HEAD=""

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
    cols=$(stty size 2>/dev/null < /dev/tty | cut -d' ' -f2 || true)
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

# Mesma escada do calc_width, pelas mesmas razoes: stty le o tamanho real por
# ioctl e responde mesmo com o painel em background; tput cai para o 24 do
# terminfo quando nao sabe.
calc_height() {
  local lines="${RALPH_WATCH_LINES:-}"

  if ! [[ "$lines" =~ ^[0-9]+$ ]]; then
    lines=$(stty size 2>/dev/null < /dev/tty | cut -d' ' -f1 || true)
  fi
  if ! [[ "$lines" =~ ^[0-9]+$ ]] || [ "$lines" -lt 10 ]; then
    lines=$(tput lines 2>/dev/null || true)
  fi
  if ! [[ "$lines" =~ ^[0-9]+$ ]] || [ "$lines" -lt 10 ]; then
    lines="${LINES:-}"
  fi
  [[ "$lines" =~ ^[0-9]+$ ]] || lines=24

  H=$lines
  [ "$H" -lt 12 ] && H=12
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

# Linhas da tabela montadas uma vez por frame, antes de saber o recorte: quem
# rola escolhe o intervalo, nao remonta o conteudo.
declare -a ROWS ROW_HL
declare -A PHASE_ROW PHASE_END
RUN_ROW=-1

build_rows() {
  ROWS=(); ROW_HL=(); PHASE_ROW=(); PHASE_END=(); RUN_ROW=-1

  # c_gates=19 cabe "G0 ✓ G1 ✓ G2 ✓ G3 ✓" inteiro; c_status=14 cabe o rotulo
  # mais longo ("▶ Em execução"). Encolher qualquer um deles corta a informacao.
  COL_ID=4; COL_STATUS=14; COL_TRY=9; COL_GATES=19
  COL_NAME=$(( W - COL_ID - COL_STATUS - COL_TRY - COL_GATES - 16 ))
  [ "$COL_NAME" -lt 16 ] && COL_NAME=16

  local V="${C_CYAN}│${C_RESET}"

  # Celula colorida com padding correto: mede o texto SEM ANSI (plain) e
  # completa a diferenca. Colorir depois de padear inflaria a largura visivel.
  cell() { # <colorido> <plain> <largura>
    local colored="$1" plain="$2" w="$3" n=${#2}
    if [ "$n" -gt "$w" ]; then printf '%s' "$(pad "$plain" "$w")"; return; fi
    printf '%s%*s' "$colored" $(( w - n )) ''
  }

  local num i st tries row
  for num in "${PHASE_NUMS[@]}"; do
    st="${PH_STATUS[$num]}"
    tries="${PH_ATTEMPT[$num]}"
    [ "$tries" = "0" ] && tries="–"

    PHASE_ROW[$num]=${#ROWS[@]}
    # a linha guarda tudo menos a borda direita: ali vai a barra de rolagem
    row=$(printf '%s %s %s %s %s %s %s %s %s %s' "$V" \
      "$(pad "F$num" $COL_ID)" "$V" \
      "$(cell "${C_WHITE}$(pad "${PH_TITLE[$num]}" $COL_NAME)${C_RESET}" "$(pad "${PH_TITLE[$num]}" $COL_NAME)" $COL_NAME)" "$V" \
      "$(cell "$(status_label "$st")" "$(status_plain "$st")" $COL_STATUS)" "$V" \
      "$(pad "$tries" $COL_TRY)" "$V" \
      "$(cell "$(gates_cell "${PH_GATES[$num]}" 1)" "$(gates_cell "${PH_GATES[$num]}" 0)" $COL_GATES)")
    ROWS+=("$row")
    if [ "$st" = "running" ]; then
      ROW_HL+=("$C_HILITE")
      [ "$RUN_ROW" -lt 0 ] && RUN_ROW=$(( ${#ROWS[@]} - 1 ))
    else
      ROW_HL+=("")
    fi

    local tst ttitle
    for ((i=1; i<=${TK_COUNT[$num]:-0}; i++)); do
      tst="${TK_STATUS[$num:$i]:-pending}"
      ttitle=$(pad "  ↳ ${TK_TITLE[$num:$i]}" $COL_NAME)
      row=$(printf '%s %s %s %s %s %s %s %s %s %s' "$V" \
        "$(cell "${C_GREY}$(pad "T$i" $COL_ID)${C_RESET}" "$(pad "T$i" $COL_ID)" $COL_ID)" "$V" \
        "$ttitle" "$V" \
        "$(cell "$(status_label "$tst")" "$(status_plain "$tst")" $COL_STATUS)" "$V" \
        "$(cell "${C_GREY}$(pad '–' $COL_TRY)${C_RESET}" "$(pad '–' $COL_TRY)" $COL_TRY)" "$V" \
        "$(cell "${C_GREY}$(pad '–' $COL_GATES)${C_RESET}" "$(pad '–' $COL_GATES)" $COL_GATES)")
      ROWS+=("$row")
      if [ "$tst" = "running" ]; then
        ROW_HL+=("$C_HILITE")
        # a task em execucao e a ancora preferida: e o que o usuario quer ver
        RUN_ROW=$(( ${#ROWS[@]} - 1 ))
      else
        ROW_HL+=("")
      fi
    done
    PHASE_END[$num]=$(( ${#ROWS[@]} - 1 ))
  done
}

clamp_off() {
  [ "$OFF" -gt "$MAX_OFF" ] && OFF=$MAX_OFF
  [ "$OFF" -lt 0 ] && OFF=0
}

# Recorte automatico: mostra o bloco da fase corrente inteiro quando ele cabe;
# quando nao cabe, centra a task em execucao.
follow_offset() {
  local cur="${META[phase_cur]:-}"
  if [ -z "$cur" ] || [ -z "${PHASE_ROW[$cur]:-}" ]; then
    # sem fase corrente (run terminado, por exemplo): mantem o comeco a vista
    OFF=0
    [ "${META[status]:-running}" = "failed" ] && [ "$RUN_ROW" -ge 0 ] \
      && OFF=$(( RUN_ROW - VIS / 2 ))
    clamp_off
    return
  fi
  local s="${PHASE_ROW[$cur]}" e="${PHASE_END[$cur]}"
  if [ $(( e - s + 1 )) -le "$VIS" ]; then
    OFF=$(( s - 1 ))   # uma linha de contexto acima da fase
  elif [ "$RUN_ROW" -ge "$s" ] && [ "$RUN_ROW" -le "$e" ]; then
    OFF=$(( RUN_ROW - VIS / 2 ))
  else
    OFF=$s
  fi
  clamp_off
}

# Define HEAD, VIS, TOTAL, MAX_OFF, FOOTER e OFF para o frame. Roda no shell
# principal (nao em subshell) porque as teclas precisam do VIS e do MAX_OFF
# calculados aqui para paginar.
build_frame() {
  calc_width
  calc_height
  build_rows

  HEAD=$(draw_header; draw_panels)
  TOTAL=${#ROWS[@]}

  local head_n note_n=0 avail
  head_n=$(printf '%s\n' "$HEAD" | wc -l)
  [ -n "${META[note]:-}" ] && note_n=2

  # 4 = topo, cabecalho de coluna, separador e rodape da tabela.
  # 1 = folga da ultima linha, que o terminal usaria para rolar o frame.
  avail=$(( H - head_n - 4 - note_n - 1 ))
  [ "$avail" -lt 3 ] && avail=3

  # --once e um dump: so recorta se a altura foi fixada de proposito.
  if { $ONCE && [ -z "${RALPH_WATCH_LINES:-}" ]; } || [ "$TOTAL" -le "$avail" ]; then
    VIS=$TOTAL; MAX_OFF=0; FOOTER=0; OFF=0
    return
  fi

  FOOTER=1
  VIS=$(( avail - 1 ))
  [ "$VIS" -lt 3 ] && VIS=3
  [ "$VIS" -gt "$TOTAL" ] && VIS=$TOTAL
  MAX_OFF=$(( TOTAL - VIS ))
  if $FOLLOW; then follow_offset; else clamp_off; fi
}

# Borda direita da linha visivel i: vira barra de rolagem quando ha corte.
scroll_edge() {
  local i="$1"
  if [ "$FOOTER" -eq 0 ]; then
    printf '%s│%s' "$C_CYAN" "$C_RESET"
    return
  fi
  local th top rel
  th=$(( VIS * VIS / TOTAL )); [ "$th" -lt 1 ] && th=1
  top=0
  [ "$MAX_OFF" -gt 0 ] && top=$(( OFF * (VIS - th) / MAX_OFF ))
  rel=$(( i - OFF ))
  if [ "$rel" -ge "$top" ] && [ "$rel" -lt $(( top + th )) ]; then
    printf '%s█%s' "$C_CYAN" "$C_RESET"
  else
    printf '%s│%s' "$C_GREY" "$C_RESET"
  fi
}

draw_table() {
  local sep_t sep_m sep_b
  sep_t=$(printf '%s┌%s┬%s┬%s┬%s┬%s┐%s' "$C_CYAN" \
    "$(repeat '─' $((COL_ID+2)))" "$(repeat '─' $((COL_NAME+2)))" "$(repeat '─' $((COL_STATUS+2)))" \
    "$(repeat '─' $((COL_TRY+2)))" "$(repeat '─' $((COL_GATES+2)))" "$C_RESET")
  sep_m=$(printf '%s├%s┼%s┼%s┼%s┼%s┤%s' "$C_CYAN" \
    "$(repeat '─' $((COL_ID+2)))" "$(repeat '─' $((COL_NAME+2)))" "$(repeat '─' $((COL_STATUS+2)))" \
    "$(repeat '─' $((COL_TRY+2)))" "$(repeat '─' $((COL_GATES+2)))" "$C_RESET")
  sep_b=$(printf '%s└%s┴%s┴%s┴%s┴%s┘%s' "$C_CYAN" \
    "$(repeat '─' $((COL_ID+2)))" "$(repeat '─' $((COL_NAME+2)))" "$(repeat '─' $((COL_STATUS+2)))" \
    "$(repeat '─' $((COL_TRY+2)))" "$(repeat '─' $((COL_GATES+2)))" "$C_RESET")

  local V="${C_CYAN}│${C_RESET}"

  printf '%s\n' "$sep_t"
  printf '%s %s %s %s %s %s %s %s %s %s %s\n' "$V" \
    "${C_CYAN}$(pad 'ID' $COL_ID)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Fase / Task' $COL_NAME)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Status' $COL_STATUS)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Tentativa' $COL_TRY)${C_RESET}" "$V" \
    "${C_CYAN}$(pad 'Gates' $COL_GATES)${C_RESET}" "$V"
  printf '%s\n' "$sep_m"

  local i
  for ((i=OFF; i<OFF+VIS && i<TOTAL; i++)); do
    printf '%s%s %s%s\n' "${ROW_HL[$i]}" "${ROWS[$i]}" "$(scroll_edge "$i")" "$C_RESET"
  done
  printf '%s\n' "$sep_b"

  [ "$FOOTER" -eq 1 ] && draw_scroll_footer
}

draw_scroll_footer() {
  local above=$OFF below=$(( TOTAL - OFF - VIS )) mode help=""
  if $FOLLOW; then
    mode="seguindo a fase atual"
  else
    mode="rolagem manual"
  fi
  if [ -n "${KEY_FD:-}" ]; then
    help=" · ↑↓ PgUp/PgDn rolam · f segue a fase"
    $EMBEDDED || help+=" · q sai"
  fi
  printf '%s  ▲ %d acima · ▼ %d abaixo · %s%s%s\n' \
    "$C_GREY" "$above" "$below" "$mode" "$help" "$C_RESET"
}

render() {
  printf '%s\n' "$HEAD"
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

# Teclado pelo /dev/tty, nao pelo stdin: com --embedded o painel e iniciado com
# `&` pelo ralph, que roda sem job control — o filho fica no mesmo grupo de
# processo em foreground, entao ler o terminal e permitido (nao ha SIGTTIN). O
# ralph ja da `< /dev/null` no engine e nos testes e le o manifest pelo fd 3,
# entao ninguem mais disputa essas teclas.
KEY_FD=""

open_keyboard() {
  $ONCE && return 0
  exec 3< /dev/tty 2>/dev/null && KEY_FD=3
  return 0
}

scroll_by() { # <delta em linhas>
  FOLLOW=false
  OFF=$(( OFF + $1 ))
  clamp_off
}

handle_key() { # <char lido>
  local c="$1" seq="" tail=""
  if [ "$c" = $'\033' ]; then
    IFS= read -rsn2 -t 0.05 -u "$KEY_FD" seq || true
    case "$seq" in
      '[A') scroll_by -1 ;;
      '[B') scroll_by 1 ;;
      '[H') FOLLOW=false; OFF=0 ;;
      '[F') FOLLOW=false; OFF=$MAX_OFF ;;
      '[5'|'[6'|'[1'|'[4')
        IFS= read -rsn1 -t 0.05 -u "$KEY_FD" tail || true   # engole o '~'
        case "$seq" in
          '[5') scroll_by -"$VIS" ;;
          '[6') scroll_by "$VIS" ;;
          '[1') FOLLOW=false; OFF=0 ;;
          '[4') FOLLOW=false; OFF=$MAX_OFF ;;
        esac
        ;;
    esac
    return
  fi
  case "$c" in
    k|K)   scroll_by -1 ;;
    j|J)   scroll_by 1 ;;
    b|B)   scroll_by -"$VIS" ;;
    ' ')   scroll_by "$VIS" ;;
    g)     FOLLOW=false; OFF=0 ;;
    G)     FOLLOW=false; OFF=$MAX_OFF ;;
    f|F)   FOLLOW=true ;;
    # embutido no ralph o painel e dono da tela alternativa que o ralph abriu:
    # sair aqui deixaria a tela congelada com o run ainda em andamento.
    q|Q)   $EMBEDDED || QUIT=true ;;
  esac
}

# Espera INTERVAL segundos, mas acorda na hora se o usuario apertar algo — e o
# que faz a rolagem responder sem esperar o proximo frame.
wait_tick() {
  local c rc
  if [ -z "$KEY_FD" ]; then
    sleep "$INTERVAL"
    return
  fi
  IFS= read -rsn1 -t "$INTERVAL" -u "$KEY_FD" c
  rc=$?
  if [ "$rc" -eq 0 ]; then
    handle_key "$c"
  elif [ "$rc" -le 128 ]; then
    # nao foi timeout: o tty sumiu. Desliga o teclado e volta ao sleep puro.
    KEY_FD=""
    exec 3<&- 2>/dev/null || true
  fi
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
    build_frame
    render
    exit 0
  fi

  open_keyboard

  local frame
  while true; do
    if read_state; then
      build_frame
      frame=$(render)
      printf '\033[H%s\033[J' "$frame"
      case "${META[status]:-running}" in
        finished|failed)
          $EMBEDDED && break
          ;;
      esac
    else
      printf '\033[H%sAguardando o ralph iniciar (%s)…%s\033[J\n' "$C_GREY" "$RUN_STATE" "$C_RESET"
    fi
    wait_tick
    $QUIT && break
  done
}

main
