#!/usr/bin/env bash
# manager.sh - remoção, resolução de dependências (topológica) e sync git/dir
# Uso:
#   ./manager.sh remove <NAME>
#   ./manager.sh resolve_deps <NAME> [NAME...]
#   ./manager.sh sync <git-repo-url> <dir-in-repo-or-local>
#
# Pressupostos:
# - Metadados gerados pelo builder/script anterior estão em $PKGOUT/*.meta
# - Cada .meta contém linhas no formato:
#     NAME=nome
#     VERSION=versão
#     DEPENDS="pkgA pkgB"
#     BIN_DIR=/var/bin
#     SOURCES_DIR=/tmp/sources
#
# - A "instalação" reside em $PKG (fakeroot); binários ficam em $PKG/var/bin
# - Logs e índice em $LOGDB

set -euo pipefail

# Configuráveis (mesmos defaults do builder)
WORK="${WORK:-/tmp/work}"
PKG="${PKG:-/tmp/pkg}"
SOURCES="${SOURCES:-/tmp/sources}"
BIN="/var/bin"                # sempre relativo a $PKG -> $PKG/var/bin
LOGDB="${LOGDB:-/var/log/meupkg}"
PKGOUT="${PKGOUT:-/tmp/packages}"
PKG_DB="$LOGDB/packages.db"

mkdir -p "$WORK" "$PKG" "$SOURCES" "$LOGDB" "$PKGOUT" "$PKG$BIN"

# --- utilidades internas ---
log() { echo "[manager] $*"; }

# encontra meta de um pacote pelo nome (procura em $PKGOUT/*.meta)
meta_for() {
    local name="$1"
    grep -lE "^NAME=${name}$" "$PKGOUT"/*.meta 2>/dev/null || true
}

# lê uma variável do arquivo .meta (VAR name meta-file)
meta_read() {
    local var="$1"
    local meta="$2"
    # shellcheck disable=SC2016
    awk -F= -v v="$var" '$1==v { sub(/^"/, "", $2); sub(/"$/, "", $2); print substr($0, index($0,$2)) }' "$meta"
}

# atualiza packages.db (formato básico: NAME VERSION TIMESTAMP)
db_add() {
    local name="$1" version="$2"
    grep -v "^${name} " "$PKG_DB" 2>/dev/null > "$PKG_DB.tmp" || true
    printf "%s %s %s\n" "$name" "$version" "$(date --iso-8601=seconds)" >> "$PKG_DB.tmp"
    mv "$PKG_DB.tmp" "$PKG_DB"
}

db_remove() {
    local name="$1"
    if [ -f "$PKG_DB" ]; then
        grep -v "^${name} " "$PKG_DB" > "$PKG_DB.tmp" || true
        mv "$PKG_DB.tmp" "$PKG_DB"
    fi
}

# --- função: remove ---
# Remove arquivos instalados pelo pacote, limpa logs/metadata e atualiza índice
remove_pkg() {
    local name="$1"
    log "Iniciando remoção de pacote: $name"

    local meta
    meta=$(meta_for "$name" || true)
    if [ -z "$meta" ]; then
        echo "Meta para pacote '$name' não encontrada em $PKGOUT. Ainda assim tentarei limpar registros."
    else
        # tenta ler where files are installed
        local bin_dir
        bin_dir=$(awk -F= '$1=="BIN_DIR"{gsub(/"/,"",$2); print $2}' "$meta" || true)
        [ -z "$bin_dir" ] && bin_dir="$BIN"
        # remove binários listados no log/metadados: prefer listar por conteúdo real em $PKG$BIN
        if [ -d "$PKG$bin_dir" ]; then
            # tenta remover arquivos que pertencem ao pacote: se existir log com lista, melhor.
            # Tentamos limpar tudo que tiver nome parecido com package name (heurística) e também consultamos log específico.
            local logfile="$LOGDB/$name-*.log"
            # remover binários correspondentes ao pacote por heurística: nomes que contenham $name
            shopt -s nullglob
            for f in "$PKG$bin_dir/"*; do
                bn=$(basename "$f")
                if [[ "$bn" == *"$name"* ]] || [ -f "$meta" ] && grep -q "Binários installed" "$meta"; then
                    rm -f "$f" && log "Removido $f"
                fi
            done
            shopt -u nullglob
        fi

        # Se houver arquivos listados no log de instalação, tente removê-los
        for lf in "$LOGDB"/"$name"-*.log; do
            [ -f "$lf" ] || continue
            # Procura por caminhos absolutos nas linhas do log e remove
            awk '
                /\/[[:alnum:]][^ ]*/ {
                    for (i=1;i<=NF;i++) {
                        if ($i ~ /^\//) print $i
                    }
                }' "$lf" | while read -r path; do
                # se path começa com $PKG, remover; se é absoluto, tentar remover equivalente em $PKG
                if [[ "$path" == "$PKG"* ]]; then
                    rm -rf "$path" && log "Removido $path"
                else
                    # transforma /usr/bin/foo -> $PKG/usr/bin/foo
                    local p2="$PKG$path"
                    [ -e "$p2" ] && rm -rf "$p2" && log "Removido $p2"
                fi
            done
            rm -f "$lf" && log "Removido log $lf"
        done

        # remover metadado
        rm -f "$meta" && log "Removido metadata $meta"
    fi

    # atualizar índice
    db_remove "$name"
    log "Pacote $name removido do índice ($PKG_DB)."
}

# --- função: resolve_deps ---
# Encontra dependências recursivas e retorna ordem topológica (dependências primeiro).
# Baseia-se nas linhas DEPENDS="pkgA pkgB" nos .meta em $PKGOUT
resolve_deps() {
    if ! command -v tsort >/dev/null 2>&1; then
        echo "Erro: 'tsort' requerido para resolve_deps. Instale coreutils (tsort)."
        return 1
    fi

    if [ "$#" -lt 1 ]; then
        echo "Uso: $0 resolve_deps <PACK1> [PACK2 ...]"
        return 1
    fi

    # coletar todos arquivos .meta e montar pares (dep -> pkg) para tsort
    local edges_file
    edges_file="$(mktemp)"
    trap 'rm -f "$edges_file"' RETURN

    # format: for each meta: for each dep in DEPENDS, print "dep pkgname"
    for meta in "$PKGOUT"/*.meta; do
        [ -f "$meta" ] || continue
        pkgname=$(awk -F= '$1=="NAME" {gsub(/"/,"",$2); print $2}' "$meta")
        depends_line=$(awk -F= '$1=="DEPENDS" {gsub(/"/,"",$2); print $2}' "$meta" 2>/dev/null || true)
        if [ -n "$depends_line" ]; then
            for dep in $depends_line; do
                printf "%s %s\n" "$dep" "$pkgname" >> "$edges_file"
            done
        fi
    done

    # tsort -> ordem (dependências antes dos dependentes)
    # Mas tsort imprime todos nós. Queremos apenas os nós necessários para os pacotes pedidos + dependências recursivas.
    # R: obter ordem topo completa, depois filtrar por alcance (nós que aparecem nas metas ou são requisitados).
    local topo_all
    topo_all=$(tsort "$edges_file" 2>/dev/null || true)

    # coletar conjunto de pacotes existentes (metas)
    declare -A exist
    for meta in "$PKGOUT"/*.meta; do
        [ -f "$meta" ] || continue
        nm=$(awk -F= '$1=="NAME" {gsub(/"/,"",$2); print $2}' "$meta")
        exist["$nm"]=1
    done

    # função recursiva para marcar alcance
    declare -A mark
    mark_recurse() {
        local p="$1"
        if [ -z "${exist[$p]:-}" ]; then
            echo "Aviso: pacote '$p' não tem metadado em $PKGOUT (faltando)."
            return
        fi
        if [ -n "${mark[$p]:-}" ]; then return; fi
        mark["$p"]=1
        # buscar dependências do p
        local meta
        meta=$(meta_for "$p" || true)
        if [ -n "$meta" ]; then
            local deps
            deps=$(awk -F= '$1=="DEPENDS" {gsub(/"/,"",$2); print $2}' "$meta" 2>/dev/null || true)
            for d in $deps; do
                mark_recurse "$d"
            done
        fi
    }

    # marcar alcance a partir dos argumentos
    for pkg in "$@"; do
        mark_recurse "$pkg"
    done

    # agora filtrar topo_all por mark[]
    # topo_all tem itens possivelmente numa linha por item; vamos preservar ordem
    local result=()
    while read -r node; do
        [ -z "$node" ] && continue
        if [ -n "${mark[$node]:-}" ]; then
            result+=("$node")
        fi
    done <<< "$topo_all"

    # finalmente, imprimir result (uma por linha). Se algum pacote requisitado não apareceu (isolado sem deps),
    # garantimos inclusão (colocando no final)
    for r in "${result[@]}"; do
        echo "$r"
    done

    for pkg in "$@"; do
        if [ -z "${mark[$pkg]:-}" ]; then
            # pacote ausente ou sem metadado; imprimir aviso e o próprio nome
            echo "Aviso: pacote '$pkg' não encontrado/sem metadado; incluindo diretamente." >&2
            echo "$pkg"
        fi
    done
}

# --- função: sync ---
# Synca $PKGOUT (pacotes e metas) para um repo git. Uso:
#   sync <git-repo-url> <dir-no-repo>
# Ex: ./manager.sh sync git@github.com:meuuser/meu-repo.git packages
sync_repo() {
    if [ "$#" -ne 2 ]; then
        echo "Uso: $0 sync <git-repo-url> <dir-no-repo>"
        return 1
    fi
    local repo="$1"
    local dir_in_repo="$2"

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    log "Clonando repo $repo em $tmpdir..."
    if ! git clone --depth 1 "$repo" "$tmpdir" 2>/dev/null; then
        # se falhar, tentar mkdir e git init? preferimos falhar para visibilidade
        echo "Falha ao clonar $repo. Verifique URL e acesso (SSH keys)." >&2
        return 1
    fi

    # garantir diretório alvo
    mkdir -p "$tmpdir/$dir_in_repo"

    # copiar pacotes e metas
    log "Copiando pacotes de $PKGOUT para $tmpdir/$dir_in_repo ..."
    rsync -a --delete "$PKGOUT"/ "$tmpdir/$dir_in_repo/"

    # commit & push
    pushd "$tmpdir" >/dev/null
    git add -A "$dir_in_repo"
    if git diff --quiet --cached; then
        log "Nada novo para commitar."
    else
        git commit -m "Sync packages: $(date --iso-8601=seconds)"
        log "Push para origin..."
        git push
    fi
    popd >/dev/null

    log "Sync concluído."
}

# --- CLI ---
case "${1:-}" in
    remove)
        if [ $# -ne 2 ]; then
            echo "Uso: $0 remove <NAME>"
            exit 1
        fi
        remove_pkg "$2"
        ;;
    resolve_deps)
        shift
        resolve_deps "$@"
        ;;
    sync)
        shift
        sync_repo "$@"
        ;;
    *)
        cat <<EOF
manager.sh - utilitários de packages

Comandos:
  remove <NAME>            Remove um pacote (limpa $PKG, /var/bin em fakeroot, logs e metadados)
  resolve_deps <NAME...>  Mostra ordem topológica de instalação (deps primeiro) usando $PKGOUT/*.meta
  sync <git-repo> <dir>   Sincroniza $PKGOUT para um repo git (clona, copia, commita, push)

Exemplos:
  ./manager.sh remove hello
  ./manager.sh resolve_deps hello libfoo
  ./manager.sh sync git@github.com:meuuser/meu-repo.git packages

Configuração via variáveis de ambiente:
  WORK, PKG, SOURCES, PKGOUT, LOGDB

EOF
        ;;
esac
