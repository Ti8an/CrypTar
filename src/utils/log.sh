#!/usr/bin/env bash
[[ -n "${_LOG_LOADED:-}" ]] && return 0
_LOG_LOADED=1

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}✅ $*${NC}"; }
log_err()  { echo -e "${RED}❌ $*${NC}" >&2; }
log_warn() { echo -e "${YELLOW}⚠️  $*${NC}" >&2; }
log_info() { echo -e "${CYAN}ℹ️  $*${NC}"; }
log_step() { echo -e "${CYAN}⏳ $*${NC}"; }
