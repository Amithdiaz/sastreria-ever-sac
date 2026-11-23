import pyodbc

SERVER_NAME = r"(local)"
DATABASE_NAME = "SastreriaEverDB"
DRIVER_NAME = "{ODBC Driver 17 for SQL Server}"


def build_conn_kwargs(auth_mode="windows", username="", password=""):
    use_sql = auth_mode == "sql"
    return {
        "use_sql_auth": use_sql,
        "username": username.strip(),
        "password": password,
    }


def get_connection(use_sql_auth=False, username="", password=""):
    if use_sql_auth:
        conn_str = (
            f"DRIVER={DRIVER_NAME};"
            f"SERVER={SERVER_NAME};"
            f"DATABASE={DATABASE_NAME};"
            f"UID={username};"
            f"PWD={password};"
            "TrustServerCertificate=yes;"
        )
    else:
        conn_str = (
            f"DRIVER={DRIVER_NAME};"
            f"SERVER={SERVER_NAME};"
            f"DATABASE={DATABASE_NAME};"
            "Trusted_Connection=yes;"
            "TrustServerCertificate=yes;"
        )
    return pyodbc.connect(conn_str)


def test_connection(conn_kwargs):
    conn = get_connection(**conn_kwargs)
    cursor = conn.cursor()
    cursor.execute("SELECT 1")
    cursor.fetchone()
    cursor.close()
    conn.close()


def fetch_all(sp_name, params=(), conn_kwargs=None):
    conn_kwargs = conn_kwargs or {}
    conn = get_connection(**conn_kwargs)
    cursor = conn.cursor()
    placeholders = ", ".join(["?"] * len(params))
    sql = f"EXEC dbo.{sp_name} {placeholders}" if params else f"EXEC dbo.{sp_name}"
    cursor.execute(sql, params)
    columns = [col[0] for col in cursor.description] if cursor.description else []
    rows = cursor.fetchall()
    cursor.close()
    conn.close()
    return columns, rows


def execute_sp(sp_name, params=(), conn_kwargs=None):
    conn_kwargs = conn_kwargs or {}
    conn = get_connection(**conn_kwargs)
    cursor = conn.cursor()
    placeholders = ", ".join(["?"] * len(params))
    sql = f"EXEC dbo.{sp_name} {placeholders}" if params else f"EXEC dbo.{sp_name}"
    cursor.execute(sql, params)
    conn.commit()
    cursor.close()
    conn.close()