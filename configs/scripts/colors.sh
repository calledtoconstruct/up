#!/bin/bash
# Shared color definitions for all Up scripts
# Source this file: source /path/to/colors.sh

# Note: Do NOT set options here as they affect the calling script
# ANSI color codes
export RED='\033[0;31m'
export GREEN='\033[0;32m'
export YELLOW='\033[1;33m'
export BLUE='\033[0;34m'
export MAGENTA='\033[0;35m'
export CYAN='\033[0;36m'
export WHITE='\033[1;37m'
export NC='\033[0m' # No Color

# Semantic colors (map to ANSI)
export COLOR_ERROR="$RED"
export COLOR_SUCCESS="$GREEN"
export COLOR_WARNING="$YELLOW"
export COLOR_INFO="$BLUE"
export COLOR_HIGHLIGHT="$CYAN"
export COLOR_PROMPT="$MAGENTA"

# Print functions for colored output
print_header() {
    echo -e "${BLUE}========================================${NC}"
}

print_section() {
    echo -e "${GREEN}==> $1${NC}"
}

print_key() {
    echo -e "  ${YELLOW}$1${NC} : $2"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_highlight() {
    echo -e "${CYAN}▶ $1${NC}"
}

# Colored message with prefix
print_colored() {
    local color="$1"
    local prefix="$2"
    local message="$3"
    echo -e "${color}${prefix}${NC} $message"
}

# Compute MD5 hash of content - used for detecting content changes
# Usage: echo "$content" | compute_hash
compute_hash() {
    md5sum | cut -d' ' -f1
}

# Read file and compute hash of its contents
# Usage: hash_file "/path/to/file"
hash_file() {
    local file="$1"
    if [ -f "$file" ]; then
        cat "$file" | compute_hash
    else
        echo ""
    fi
}

# Compare content against a stored hash file, returns 0 if different, 1 if same
# Usage: content_changed "hash_file_path" <<< "$new_content"
content_changed() {
    local hash_file="$1"
    local new_hash
    new_hash=$(compute_hash)
    
    if [ -f "$hash_file" ]; then
        local old_hash
        old_hash=$(cat "$hash_file")
        if [ "$new_hash" = "$old_hash" ]; then
            return 1  # Content is the same
        fi
    fi
    
    # Store new hash
    echo "$new_hash" > "$hash_file"
    return 0  # Content is different
}
