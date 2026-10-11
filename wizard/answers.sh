    echo "USE_BROWSER='$([ "${wizard_browser_on:-false}" = true ] && echo 1 || echo 0)'"
    echo "PROTECT='$([ "${wizard_protect_off:-false}" = true ] && echo 0 || echo 1)'"
