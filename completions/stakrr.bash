# Bash completion for stakrr. Source this file from ~/.bashrc.

_stakrr()
{
    local cur=${COMP_WORDS[COMP_CWORD]} prev=${COMP_WORDS[COMP_CWORD-1]}
    local command=${COMP_WORDS[1]} words='' flag=$prev prefix='' candidate i
    COMPREPLY=()

    if (( COMP_CWORD == 1 )); then
        words='init cut status reset version fix go up down restack continue abort log quit help --help -h --version'
    else
        # Handle both forms of --option=value, including Bash's default '=' split.
        case $cur in
            --base=*|--at=*) flag=${cur%%=*}; prefix=$flag=; cur=${cur#*=} ;;
            =) cur= ;;
        esac
        if [[ $prev == = && $COMP_CWORD -ge 3 ]]; then
            flag=${COMP_WORDS[COMP_CWORD-2]}
        fi

        case $command:$flag in
            init:--base)
                words=$(git for-each-ref --format='%(refname:strip=2)' refs/heads/ 2>/dev/null)
                ;;
            cut:--at)
                words="HEAD $(git for-each-ref --format='%(refname:short)' refs/heads/ refs/remotes/ refs/tags/ 2>/dev/null)"
                ;;
            *)
                case $command in
                    init)
                        (( COMP_CWORD == 2 )) && words=--base
                        ;;
                    cut)
                        for ((i=2; i<COMP_CWORD; i++)); do
                            case ${COMP_WORDS[i]} in --at|--at=*) return 0 ;; esac
                        done
                        words=--at
                        ;;
                    go)
                        (( COMP_CWORD == 2 )) || return 0
                        words=$(git for-each-ref --format='%(refname:strip=3)' refs/heads/stakrr/ 2>/dev/null)
                        ;;
                    fix)
                        [[ $prev == -m ]] && return 0
                        local layer='' mode=''
                        for ((i=2; i<COMP_CWORD; i++)); do
                            case ${COMP_WORDS[i]} in
                                -m) mode=1; ((i++)) ;;
                                --amend) mode=1 ;;
                                -*) ;;
                                *) layer=1 ;;
                            esac
                        done
                        if [[ -z $mode ]]; then words='-m --amend'; fi
                        if [[ -z $layer ]]; then
                            words="$words $(git for-each-ref --format='%(refname:strip=3)' refs/heads/stakrr/ 2>/dev/null)"
                        fi
                        ;;
                    reset)
                        (( COMP_CWORD == 2 )) && words=--delete-layers
                        ;;
                esac
                ;;
        esac
    fi

    # Git ref names contain no whitespace; match them without expanding shell syntax.
    while IFS= read -r candidate; do
        [[ -n $candidate && $candidate == "$cur"* ]] || continue
        COMPREPLY[${#COMPREPLY[@]}]=$prefix$candidate
    done <<< "${words// /$'\n'}"
    return 0
}

complete -F _stakrr stakrr
