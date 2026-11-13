#!/usr/bin/env bash
# Casdoor-specific app.conf rendering. This file is sourced by cli.sh.

app_conf_path() {
    printf '%s/data/%s_config/app.conf' "$CONF_DIR" "$INSTANCE_NAME"
}

quote_postgres_value() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\'/\\\'}"
    printf "'%s'" "$value"
}

render_app_conf() {
    local app_conf db_host db_port db_name db_user db_password db_sslmode data_source
    db_host="$(quote_postgres_value "$DB_HOST")"
    db_port="$(quote_postgres_value "$DB_PORT")"
    db_name="$(quote_postgres_value "$DB_NAME")"
    db_user="$(quote_postgres_value "$DB_USER")"
    db_password="$(quote_postgres_value "$DB_PASSWORD")"
    db_sslmode="$(quote_postgres_value "$DB_SSLMODE")"
    data_source="user=$db_user password=$db_password host=$db_host port=$db_port sslmode=$db_sslmode dbname=$db_name"

    data_source="$(printf '%s' "$data_source" | sed 's/[\\&|]/\\&/g')"
    app_conf="$(app_conf_path)"
    mkdir -p "$(dirname "$app_conf")"
    (
        umask 077
        sed -e "s|{{CASDOOR_DATA_SOURCE_NAME}}|$data_source|g" \
            -e "s|{{CASDOOR_DB_NAME}}|$DB_NAME|g" \
            "$TPL_DIR/app.conf.tpl" > "$app_conf"
    )
    chmod 600 "$app_conf"
    APP_CONF_HASH="$(sha256sum "$app_conf" | cut -d ' ' -f 1)"
    export APP_CONF_HASH
}

