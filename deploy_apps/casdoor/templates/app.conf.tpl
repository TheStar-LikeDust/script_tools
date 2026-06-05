appname = casdoor
httpport = 8000
runmode = prod
sessionon = true
copyrequestbody = true

driverName = postgres
dataSourceName = user={{CASDOOR_DB_USER}} password={{CASDOOR_DB_PASSWORD}} host={{CASDOOR_DB_HOST}} port={{CASDOOR_DB_PORT}} sslmode=disable dbname={{CASDOOR_DB_BOOTSTRAP}}
dbName = {{CASDOOR_DB_NAME}}

enableGzip = true
sessionTimeout = 3600
