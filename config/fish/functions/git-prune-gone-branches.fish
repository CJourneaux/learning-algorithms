# Delete local branches whose remote branch is gone, once GitHub confirms the local
# tip was one of the commits that got squashed into a merged PR.
function git-prune-gone-branches --description "Delete local branches whose merged remote branch is gone"
    argparse n/dry-run -- $argv
    or return 1

    git fetch --prune --quiet
    or return $status

    # A width like %8s counts the colour escape bytes, so a coloured cell comes out
    # 8 columns short of a plain header. Pad the plain text first, colour after.
    set -l fmt '%s %s  %-44s  %s\n'

    set -l status_local (colour blue (string pad -w 8 '[local]'))
    set -l status_remote (colour green (string pad -w 8 '[remote]'))
    set -l status_gone (colour red (string pad -w 8 '[gone]'))

    set -l action_skip (colour green (string pad -w 6 SKIP))
    set -l action_delete (colour red (string pad -w 6 DELETE))

    set -l current (git branch --show-current)
    set -l deleted 0
    set -l active 0
    set -l skipped 0

    printf $fmt (string pad -w 8 STATUS) (string pad -w 6 ACTION) BRANCH REASON

    for line in (git for-each-ref --format '%(refname:short) %(upstream:short) %(upstream:track)' refs/heads)
        set -l parts (string split ' ' -- $line)
        set -l branch $parts[1]

        if not string match -q '* [gone]' -- $line
            if test -z "$parts[2]"
                printf $fmt $status_local $action_skip $branch (colour -i blue "never pushed to a remote")
                set skipped (math $skipped + 1)
            else
                printf $fmt $status_remote $action_skip $branch (colour -i blue "still on the remote")
                set active (math $active + 1)
            end
            continue
        end

        if test "$branch" = "$current"
            printf $fmt $status_gone $action_skip $branch (colour -i yellow "currently checked out")
            set skipped (math $skipped + 1)
            continue
        end

        set -l tip (git rev-parse $branch)
        set -l short (string sub -l 9 $tip)
        set -l tip_status "searching for $short among PR(s)"
        set -l must_confirm_deletion true

        # A branch can carry several PRs, so ask for all of them: a PR keeps listing
        # its commits after the branch is deleted, and a merged one holding our tip
        # is the proof that the squash carried all of our work. Merged PRs are
        # sorted first so they win over a closed PR holding the same tip.
        set -l prs (gh pr list --head $branch --state all --json number,state,commits --jq 'sort_by(.state != "MERGED")[] | [.state, (.number|tostring)] + [.commits[].oid] | join(" ")' 2>/dev/null)

        if not set -q prs[1]
            set tip_status "no PR found"
            # printf $fmt $status_gone $action_skip $branch (colour -i blue "no PR found")
            # set skipped (math $skipped + 1)
            # continue
        else 
            set tip_status "local tip is in none of its "(count $prs)" PR(s)"
            for pr in $prs
                set -l fields (string split ' ' -- $pr)
                if contains -- $tip $fields[3..-1]
                    set -l state $fields[1]
                    set -l number $fields[2]

                    # The jq sort puts every MERGED PR ahead of the rest, so the first
                    # PR holding the tip is a merged one whenever one exists.
                    if test "$state" = MERGED
                        set tip_status "local tip is in merged PR #$number"
                        set must_confirm_deletion false
                        break
                    else if test "$state" = CLOSED
                        set tip_status "local tip is in closed PR #$number"
                        break
                    else
                        # This should never be happening for a branch that is [gone], keeping it as a fallback for safety
                        set tip_status "local tip is in open PR #$number ($state)"
                        break
                    end
                end
            end
        end

        set -l why "$tip_status"
        if test "$must_confirm_deletion" = true
            # PR status does not allow to delete without asking the user for confirmation
            read -l -P "$branch — $tip_status. Delete anyway? [y/N] " confirm
            if not string match -qi 'y*' -- $confirm
                printf $fmt $status_gone $action_skip $branch (colour -i blue "kept on request, $tip_status")
                set skipped (math $skipped + 1)
                continue
            end
            set why "deleted on request, $tip_status"
        end

        if set -q _flag_dry_run
            printf $fmt $status_gone $action_delete $branch (colour -i yellow "$why (was $short) — dry run, nothing deleted")
            set deleted (math $deleted + 1)
        else if git branch -D $branch >/dev/null
            printf $fmt $status_gone $action_delete $branch (colour -i yellow "$why (was $short)")
            set deleted (math $deleted + 1)
        else
            printf $fmt $status_gone $action_delete $branch (colour -i red "git refused to delete it")
            set skipped (math $skipped + 1)
        end
    end

    echo
    if set -q _flag_dry_run
        echo "$deleted branches would be deleted, $active still active on the remote, $skipped skipped"
    else
        echo "$deleted branches deleted, $active still active on the remote, $skipped skipped"
    end
end
