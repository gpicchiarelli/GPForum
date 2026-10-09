# shellcheck shell=sh
# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause
#
# The command line's words for the shell scripts that run before Perl's
# dependencies exist (script/gpforum-system-perl, script/system-preflight):
# the same catalogs GPForum::Service::I18N::CliCatalog reads, locale/cli/en.po
# and it.po, in the language LC_ALL, LC_MESSAGES or LANG names, read with
# awk. Sourced, not run; the sourcing script sets $root to the checkout.
#
#   words_say KEY 'English text with {name}' name=value ...
#
# prints the key's text in the operator's language with each {name} filled
# in. The English given is what en.po says (t/492 holds them equal); it is
# used when the catalogs are not there, as in a bare copy of the script.

# it or en: the first of LC_ALL, LC_MESSAGES and LANG that is set decides,
# as it does for every other program; Italian for it, it_IT.UTF-8 and the
# like, English for anything else.
words_language() {
    for words_value in "${LC_ALL:-}" "${LC_MESSAGES:-}" "${LANG:-}"; do
        [ -n "$words_value" ] || continue
        case "$words_value" in
            [Ii][Tt] | [Ii][Tt][_.@-]*) echo it ;;
            *) echo en ;;
        esac
        return 0
    done
    echo en
}

# The msgstr of a msgctxt in a PO file, its continuation lines joined and
# its escapes read; nothing when the file lacks it.
words_lookup() {
    awk -v key="$1" '
        function unquote(text) {
            sub(/^[ \t]*"/, "", text)
            sub(/"[ \t]*$/, "", text)
            gsub(/\\"/, "\"", text)
            gsub(/\\\\/, "\\", text)
            return text
        }
        $0 == "msgctxt \"" key "\"" { found = 1; next }
        found && /^msgstr / { taking = 1; sub(/^msgstr /, ""); out = unquote($0); next }
        found && taking && /^[ \t]*"/ { out = out unquote($0); next }
        found && taking { exit }
        END { if (taking) printf "%s", out }
    ' "$2" 2>/dev/null
}

words_say() {
    words_key=$1
    words_text=$2
    shift 2

    words_file="${root:-.}/locale/cli/$(words_language).po"
    if [ -r "$words_file" ]; then
        words_found=$(words_lookup "$words_key" "$words_file")
        if [ -n "$words_found" ]; then
            words_text=$words_found
        fi
    fi

    for words_pair in "$@"; do
        words_name=${words_pair%%=*}
        words_value=${words_pair#*=}
        while :; do
            case "$words_text" in
                *"{$words_name}"*)
                    words_text="${words_text%%"{$words_name}"*}$words_value${words_text#*"{$words_name}"}"
                    ;;
                *) break ;;
            esac
        done
    done

    printf '%s\n' "$words_text"
}

# A finding's line, marked as GPForum::Service::Operations::Findings marks
# it: ok, degraded or fail, then the text.
words_mark() {
    case "$1" in
        ok) printf '\342\234\223 %s\n' "$2" ;;
        degraded) printf '! %s\n' "$2" ;;
        *) printf '\342\234\227 %s\n' "$2" ;;
    esac
}

# The fixes under a problem: the first behind "Fix: " in the operator's
# language, each one after it aligned under the first's text.
words_fixes() {
    words_first=1
    words_prefix=$(words_say findings.fix 'Fix: {fix}' fix=)
    words_pad=$(printf '%s' "$words_prefix" | sed 's/./ /g')
    for words_fix in "$@"; do
        if [ "$words_first" -eq 1 ]; then
            printf '    %s%s\n' "$words_prefix" "$words_fix"
            words_first=0
        else
            printf '    %s%s\n' "$words_pad" "$words_fix"
        fi
    done
}

# The closing line: nothing to fix, one thing, or how many.
words_summary() {
    case "$1" in
        0) words_say findings.summary_none 'Nothing to fix.' ;;
        1) words_say findings.summary_one '1 thing to fix.' ;;
        *) words_say findings.summary_many '{count} things to fix.' "count=$1" ;;
    esac
}
