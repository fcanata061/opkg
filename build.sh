#!/bin/bash
set -euo pipefail

WORK="${WORK:-/tmp/work}"
PKG="${PKG:-/tmp/pkg}"
SOURCES="${SOURCES:-/tmp/sources}"
BIN="/var/bin"
LOGDB="/var/log/meupkg"
PKGOUT="${PKGOUT:-/tmp/packages}"

mkdir -p "$WORK" "$PKG" "$SOURCES" "$LOGDB" "$PKGOUT" "$PKG$BIN"

# Função de download
fetch() {
    url="$1"
    cd "$SOURCES"
    case "$url" in
        *.git) 
            git clone "$url" "$WORK/$(basename "$url" .git)"
            ;;
        http*://*)
            if command -v curl >/dev/null; then
                curl -L -O "$url"
            else
                wget "$url"
            fi
            ;;
        *)
            echo "URL não suportada: $url"
            exit 1
            ;;
    esac
}

# Função de extração
extract() {
    file="$1"
    cd "$WORK"
    case "$file" in
        *.tar.gz|*.tgz) tar xvf "$SOURCES/$file" ;;
        *.tar.bz2) tar xvjf "$SOURCES/$file" ;;
        *.tar.xz) tar xvf "$SOURCES/$file" ;;
        *.zip) unzip "$SOURCES/$file" ;;
        *.gz) gunzip -c "$SOURCES/$file" > "${file%.gz}" ;;
        *.bz2) bunzip2 -c "$SOURCES/$file" > "${file%.bz2}" ;;
        *.xz) unxz -c "$SOURCES/$file" > "${file%.xz}" ;;
        *)
            echo "Formato não suportado: $file"
            ;;
    esac
}

prepare() {
    recipe="$1"
    source "$recipe"

    fetch "$SOURCE"
    if [ -f "$SOURCES/$(basename $SOURCE)" ]; then
        extract "$(basename $SOURCE)"
    fi

    if [ -n "${EXTRA_SOURCES:-}" ]; then
        for src in $EXTRA_SOURCES; do
            fetch "$src"
            if [ -f "$SOURCES/$(basename $src)" ]; then
                extract "$(basename $src)"
            fi
        done
    fi

    cd "$WORK/$PKGDIR"
    if [ -n "${PATCHES:-}" ]; then
        for p in $PATCHES; do
            patch -p1 < "$p"
        done
    fi
}

build() {
    recipe="$1"
    source "$recipe"
    cd "$WORK/$PKGDIR"
    eval "$BUILD"
}

install_pkg() {
    local recipe="$1"
    declare -A visited
    _install_recursive() {
        local r="$1"
        [ -f "$r" ] || err "Receita não encontrada: $r"
        source "$r"

        # Evitar ciclos
        if [ "${visited[$NAME]:-0}" -eq 1 ]; then
            return
        fi
        visited["$NAME"]=1

        # Resolver dependências recursivas
        for dep in ${DEPENDS:-}; do
            if ! ls "$LOGDB/$dep-"*.files >/dev/null 2>&1; then
                local dep_recipe="recipes/$dep.recipe"
                if [ -f "$dep_recipe" ]; then
                    log "Instalando dependência: $dep"
                    _install_recursive "$dep_recipe"
                else
                    err "Receita da dependência '$dep' não encontrada"
                fi
            else
                log "Dependência $dep já instalada"
            fi
        done

        # Instalar o pacote atual
        cd "$WORK/$PKGDIR"
        rm -rf "$PKG"/*

        log "Instalando $NAME..."
        fakeroot bash -c "$INSTALL"

        mkdir -p "$PKG$BIN"
        if [ -d "$PKG/usr/bin" ]; then
            mv "$PKG/usr/bin/"* "$PKG$BIN/" 2>/dev/null || true
            rm -rf "$PKG/usr/bin"
        fi

        # Registrar arquivos instalados
        FILELIST="$LOGDB/$NAME-$VERSION.files"
        (cd "$PKG"; find . -type f -o -type l) | sed 's|^\./|/|' > "$FILELIST"

        # Criar log humano
        LOGFILE="$LOGDB/$NAME-$VERSION.log"
        {
            echo "Pacote: $NAME"
            echo "Versão: $VERSION"
            echo "Fonte: $SOURCE"
            echo "Dependências: ${DEPENDS:-}"
            echo "Binários em: $BIN"
            echo "Arquivos instalados: $FILELIST"
        } > "$LOGFILE"

        # Empacotar
        package "$r"
    }

    _install_recursive "$recipe"
}

package() {
    recipe="$1"
    source "$recipe"

    cd "$PKG"
    PKGFILE="$PKGOUT/${NAME}-${VERSION}.tar.xz"
    tar -cJf "$PKGFILE" *

    # Gera metadados .meta
    META="$PKGOUT/${NAME}-${VERSION}.meta"
    {
        echo "NAME=$NAME"
        echo "VERSION=$VERSION"
        echo "SOURCE=$SOURCE"
        echo "EXTRA_SOURCES=${EXTRA_SOURCES:-}"
        echo "DEPENDS=${DEPENDS:-}"
        echo "SOURCES_DIR=$SOURCES"
        echo "BIN_DIR=$BIN"
    } > "$META"

    # Gera package.json
    FILELIST="$LOGDB/$NAME-$VERSION.files"
    JSON="$PKGOUT/${NAME}-${VERSION}.json"
    {
        echo "{"
        echo "  \"name\": \"$NAME\","
        echo "  \"version\": \"$VERSION\","
        echo "  \"source\": \"$SOURCE\","
        echo "  \"extra_sources\": [$(for s in ${EXTRA_SOURCES:-}; do echo -n "\"$s\","; done | sed 's/,$//')],"
        echo "  \"depends\": [$(for d in ${DEPENDS:-}; do echo -n "\"$d\","; done | sed 's/,$//')],"
        echo "  \"bin_dir\": \"$BIN\","
        echo "  \"sources_dir\": \"$SOURCES\","
        echo "  \"files\": ["
        if [ -f "$FILELIST" ]; then
            awk '{print "    \""$0"\","}' "$FILELIST" | sed '$ s/,$//'
        fi
        echo "  ]"
        echo "}"
    } > "$JSON"

    echo "Pacote gerado: $PKGFILE"
    echo "Meta: $META"
    echo "JSON: $JSON"
}

case "$1" in
    prepare) prepare "$2" ;;
    build) build "$2" ;;
    install) install_pkg "$2" ;;
    package) package "$2" ;;
    *) echo "Uso: $0 {prepare|build|install|package} receita" ;;
esac
