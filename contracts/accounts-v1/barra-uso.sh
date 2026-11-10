# accounts-v1 §2.4: bloque para la barra de estado de Claude Code (statusLine), tras saber la cuenta.
# Guarda lo que Claude acaba de decir de sus límites (`rate_limits` del JSON de entrada), con la cuenta
# y la hora, en <CLAUDE_CONFIG_DIR o ~/.claude>/uniconnect-uso.json. Escritura atómica; nunca rompe la barra.
# Necesita: $input (el JSON de entrada), $cuenta (email de oauthAccount o vacío) y jq.
uso_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [ -n "$cuenta" ] && [ -d "$uso_dir" ]; then
  rl=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
  if [ -n "$rl" ] && [ "$rl" != "null" ]; then
    tmp="$uso_dir/.uniconnect-uso.$$"
    if jq -cn --arg e "$cuenta" --argjson r "$rl" --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
         '{version:1,email:$e,observed_at:$t,rate_limits:$r}' > "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$uso_dir/uniconnect-uso.json" 2>/dev/null || rm -f "$tmp"
    else
      rm -f "$tmp"
    fi
  fi
fi
