#!/bin/bash
set -e

# Diretórios padrão
WORK="${WORK:-/tmp/work}"          # Área de build
PKG="${PKG:-/tmp/pkg}"             # Área de instalação (fakeroot)
SOURCES="${SOURCES:-/tmp/sources}" # Onde ficam os arquivos baixados
BIN="/var/bin"                     # Binários irão para /var/bin no pacote
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

# Função prepare: baixa, extrai e aplica patch
prepare() {
    recipe="$1"
    source "$recipe"

    # Fonte principal
    fetch "$SOURCE"
    if [ -f "$SOURCES/$(basename $SOURCE)" ]; then
        extract "$(basename $SOURCE)"
    fi

    # Fontes adicionais
    if [ -n "$EXTRA_SOURCES" ]; then
        for src in $EXTRA_SOURCES; do
            fetch "$src"
            if [ -f "$SOURCES/$(basename $src)" ]; then
                extract "$(basename $src)"
            fi
        done
    fi

    # Entra no diretório do pacote
    cd "$WORK/$PKGDIR"

    # Aplica patches se houver
    if [ -n "$PATCHES" ]; then
        for p in $PATCHES; do
            patch -p1 < "$p"
        done
    fi
}

# Função build: compila
build() {
    recipe="$1"
    source "$recipe"

    cd "$WORK/$PKGDIR"
    eval "$BUILD"
}

# Função install: instala em $PKG
install_pkg() {
    recipe="$1"
    source "$recipe"

    cd "$WORK/$PKGDIR"
    fakeroot bash -c "$INSTALL"

    # Garantir que os binários fiquem em /var/bin
    mkdir -p "$PKG$BIN"
    if [ -d "$PKG/usr/bin" ]; then
        mv "$PKG/usr/bin/"* "$PKG$BIN/" 2>/dev/null || true
        rm -rf "$PKG/usr/bin"
    fi

    # Registro da instalação
    LOGFILE="$LOGDB/$NAME-$VERSION.log"
    {
        echo "Pacote: $NAME"
        echo "Versão: $VERSION"
        echo "Fonte principal: $SOURCE"
        echo "Fontes baixadas: $SOURCES"
        echo "Binários instalados em: $BIN"
        ls "$PKG$BIN" || echo "Nenhum binário encontrado"
    } > "$LOGFILE"
}

# Função package: empacota instalação e gera metadata
package() {
    recipe="$1"
    source "$recipe"

    cd "$PKG"

    PKGFILE="$PKGOUT/${NAME}-${VERSION}.tar.xz"
    tar -cJf "$PKGFILE" *

    # Metadados
    META="$PKGOUT/${NAME}-${VERSION}.meta"
    {
        echo "NAME=$NAME"
        echo "VERSION=$VERSION"
        echo "SOURCE=$SOURCE"
        echo "EXTRA_SOURCES=$EXTRA_SOURCES"
        echo "SOURCES_DIR=$SOURCES"
        echo "BIN_DIR=$BIN"
    } > "$META"

    echo "Pacote gerado: $PKGFILE"
    echo "Metadados: $META"
}

# Execução principal
case "$1" in
    prepare) prepare "$2" ;;
    build) build "$2" ;;
    install) install_pkg "$2" ;;
    package) package "$2" ;;
    *)
        echo "Uso: $0 {prepare|build|install|package} receita"
        ;;
esac
