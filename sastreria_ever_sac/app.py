from datetime import date, timedelta
from functools import wraps
from flask import Flask, render_template, request, redirect, url_for, session
from db import build_conn_kwargs, test_connection, fetch_all, execute_sp

app = Flask(__name__)
app.secret_key = "sastreria-ever-sac-clave-local-2026"

ESTADOS_PEDIDO = [
    "Pendiente",
    "En Corte",
    "En Confección",
    "En Prueba",
    "Terminado",
    "Entregado",
    "Anulado",
]

PRENDAS_VALIDAS = ["Terno", "Saco", "Pantalón", "Chaleco", "Camisa"]
CORTES_VALIDOS = ["Slim Fit", "Clásico", "Regular", "Entallado"]
TIPOS_COMPROBANTE = ["Boleta", "Factura"]
MEDIOS_PAGO = ["Efectivo", "Yape", "Plin", "Tarjeta", "Transferencia"]


def _to_float_or_none(val):
    if val is None:
        return None
    s = str(val).strip()
    if not s:
        return None
    return float(s)


def login_required(f):
    @wraps(f)
    def decorated(*args, **kwargs):
        if not session.get("logged_in"):
            return redirect(url_for("login"))
        return f(*args, **kwargs)
    return decorated


@app.route("/")
def index():
    if session.get("logged_in"):
        return redirect(url_for("menu"))
    return redirect(url_for("login"))


@app.route("/login", methods=["GET", "POST"])
def login():
    error = None
    auth_mode = "windows"
    username = ""

    if request.method == "POST":
        auth_mode = request.form.get("auth_mode", "windows")
        username = request.form.get("username", "").strip()
        password = request.form.get("password", "")

        conn_kwargs = build_conn_kwargs(auth_mode, username, password)
        try:
            test_connection(conn_kwargs)
            session["logged_in"] = True
            session["conn_kwargs"] = conn_kwargs
            session["display_user"] = username if auth_mode == "sql" and username else "Windows Auth"
            return redirect(url_for("menu"))
        except Exception as e:
            error = f"Error al conectar con SQL Server: {e}"

    return render_template("login.html", error=error, auth_mode=auth_mode, username=username)


@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("login"))


@app.route("/menu")
@login_required
def menu():
    return render_template("menu.html", active_page="menu")


@app.route("/pedidos/nuevo", methods=["GET", "POST"])
@login_required
def nuevo_pedido():
    conn_kwargs = session.get("conn_kwargs")
    error = None
    exito = None

    _, clientes_rows = fetch_all("sp_ListarClientes", ("",), conn_kwargs)
    _, telas_rows = fetch_all("sp_ListarTelas", (), conn_kwargs)

    form_data = request.form.to_dict() if request.method == "POST" else {
        "fecha_entrega": (date.today() + timedelta(days=7)).isoformat(),
        "mano_obra": "120.00",
        "tipo_comprobante": "Boleta",
        "medio_pago": "Yape",
    }

    if request.method == "POST":
        try:
            id_cliente = int(request.form.get("id_cliente", "0"))
            id_tela = int(request.form.get("id_tela", "0"))
            tipo_prenda = request.form.get("tipo_prenda", "").strip()
            tipo_corte = request.form.get("tipo_corte", "").strip()
            metros_req = _to_float_or_none(request.form.get("metros_requeridos"))
            mano_obra = _to_float_or_none(request.form.get("mano_obra"))
            fecha_entrega = request.form.get("fecha_entrega", "").strip()

            largo_saco = _to_float_or_none(request.form.get("largo_saco"))
            pecho = _to_float_or_none(request.form.get("pecho"))
            cintura = _to_float_or_none(request.form.get("cintura"))
            hombros = _to_float_or_none(request.form.get("hombros"))
            largo_manga = _to_float_or_none(request.form.get("largo_manga"))
            largo_pantalon = _to_float_or_none(request.form.get("largo_pantalon"))
            observaciones = (request.form.get("observaciones") or "").strip() or None

            tipo_comprobante = request.form.get("tipo_comprobante", "").strip()
            serie_numero = (request.form.get("serie_numero") or "").strip()
            medio_pago = request.form.get("medio_pago", "").strip()

            if id_cliente <= 0 or id_tela <= 0:
                raise ValueError("Selecciona un cliente y una tela válidos.")
            if tipo_prenda not in PRENDAS_VALIDAS:
                raise ValueError("Selecciona un tipo de prenda válido.")
            if tipo_corte not in CORTES_VALIDOS:
                raise ValueError("Selecciona un tipo de corte válido.")
            if metros_req is None or metros_req <= 0:
                raise ValueError("Los metros requeridos deben ser mayor a 0.")
            if mano_obra is None or mano_obra < 0:
                raise ValueError("La mano de obra no puede ser negativa.")
            if not fecha_entrega:
                raise ValueError("Indica la fecha de entrega.")
            if tipo_comprobante not in TIPOS_COMPROBANTE:
                raise ValueError("Selecciona Boleta o Factura.")
            if not serie_numero:
                raise ValueError("Ingresa el número de serie/comprobante (ej. B001-009999).")
            if medio_pago not in MEDIOS_PAGO:
                raise ValueError("Selecciona un medio de pago válido.")

            params = (
                id_cliente,
                id_tela,
                tipo_prenda,
                tipo_corte,
                metros_req,
                mano_obra,
                fecha_entrega,
                largo_saco,
                pecho,
                cintura,
                hombros,
                largo_manga,
                largo_pantalon,
                observaciones,
                tipo_comprobante,
                serie_numero,
                medio_pago,
            )
            execute_sp("sp_RegistrarPedidoCompleto", params, conn_kwargs)
            exito = f"Pedido registrado correctamente con comprobante {serie_numero}."
            form_data = {
                "fecha_entrega": (date.today() + timedelta(days=7)).isoformat(),
                "mano_obra": "120.00",
                "tipo_comprobante": "Boleta",
                "medio_pago": "Yape",
            }
            _, telas_rows = fetch_all("sp_ListarTelas", (), conn_kwargs)

        except Exception as exc:
            error = str(exc)

    return render_template(
        "nuevo_pedido.html",
        active_page="nuevo_pedido",
        clientes=clientes_rows,
        telas=telas_rows,
        prendas=PRENDAS_VALIDAS,
        cortes=CORTES_VALIDOS,
        tipos_comprobante=TIPOS_COMPROBANTE,
        medios_pago=MEDIOS_PAGO,
        form_data=form_data,
        error=error,
        exito=exito,
    )


@app.route("/pedidos", methods=["GET", "POST"])
@login_required
def pedidos():
    conn_kwargs = session.get("conn_kwargs")
    error = None
    exito = None
    medidas_detalle = None
    id_pedido_medidas = request.args.get("medidas_id", type=int)

    if request.method == "POST":
        accion = request.form.get("accion", "")
        if accion == "cambiar_estado":
            try:
                id_pedido = int(request.form.get("id_pedido", "0"))
                nuevo_estado = request.form.get("nuevo_estado", "").strip()
                if id_pedido <= 0 or nuevo_estado not in ESTADOS_PEDIDO:
                    raise ValueError("Datos inválidos para actualizar el estado.")
                execute_sp("sp_ActualizarEstadoPedido", (id_pedido, nuevo_estado), conn_kwargs)
                exito = f"Estado del pedido #{id_pedido} actualizado a '{nuevo_estado}'."
                id_pedido_medidas = id_pedido
            except Exception as exc:
                error = str(exc)

    filtro = (request.args.get("filtro") or "").strip()
    estado_filtro = (request.args.get("estado") or "").strip()

    _, pedidos_rows = fetch_all("sp_ListarPedidosDetalle", (filtro,), conn_kwargs)
    if estado_filtro:
        pedidos_rows = [r for r in pedidos_rows if r[7] == estado_filtro]

    if id_pedido_medidas:
        _, med_rows = fetch_all("sp_ConsultarMedidasPedido", (id_pedido_medidas,), conn_kwargs)
        if med_rows:
            medidas_detalle = med_rows[0]

    return render_template(
        "pedidos.html",
        active_page="pedidos",
        pedidos=pedidos_rows,
        filtro=filtro,
        estado_filtro=estado_filtro,
        estados=ESTADOS_PEDIDO,
        medidas_detalle=medidas_detalle,
        id_pedido_medidas=id_pedido_medidas,
        error=error,
        exito=exito,
    )


@app.route("/inventario", methods=["GET", "POST"])
@login_required
def inventario():
    conn_kwargs = session.get("conn_kwargs")
    error = None
    exito = None

    if request.method == "POST":
        accion = request.form.get("accion", "")
        try:
            if accion == "registrar_tela":
                codigo = (request.form.get("codigo_tela") or "").strip()
                nombre = (request.form.get("nombre_tela") or "").strip()
                color = (request.form.get("color") or "").strip()
                precio = _to_float_or_none(request.form.get("precio_metro"))
                stock = _to_float_or_none(request.form.get("stock_metros"))

                if not codigo or not nombre or not color:
                    raise ValueError("Completa código, nombre y color de la tela.")
                if precio is None or precio <= 0:
                    raise ValueError("El precio por metro debe ser mayor a 0.")
                if stock is None or stock < 0:
                    raise ValueError("El stock inicial no puede ser negativo.")

                execute_sp("sp_RegistrarTela", (codigo, nombre, color, precio, stock), conn_kwargs)
                exito = f"Tela '{codigo} - {nombre}' registrada correctamente."

            elif accion == "actualizar_tela":
                id_tela = int(request.form.get("id_tela", "0"))
                metros_add = _to_float_or_none(request.form.get("metros_adicionales"))
                nuevo_precio = _to_float_or_none(request.form.get("nuevo_precio"))

                if id_tela <= 0:
                    raise ValueError("Selecciona una tela válida.")
                if metros_add is None or metros_add < 0:
                    raise ValueError("Los metros adicionales no pueden ser negativos.")
                if nuevo_precio is None or nuevo_precio <= 0:
                    raise ValueError("El nuevo precio por metro debe ser mayor a 0.")

                execute_sp("sp_ActualizarStockTela", (id_tela, metros_add, nuevo_precio), conn_kwargs)
                exito = f"Stock y precio actualizados para la tela ID #{id_tela}."

            elif accion == "desactivar_tela":
                id_tela = int(request.form.get("id_tela", "0"))
                if id_tela <= 0:
                    raise ValueError("ID de tela inválido.")
                execute_sp("sp_DesactivarTela", (id_tela,), conn_kwargs)
                exito = f"Tela ID #{id_tela} desactivada del inventario activo."

        except Exception as exc:
            error = str(exc)

    _, telas_rows = fetch_all("sp_ListarTelas", (), conn_kwargs)
    return render_template(
        "inventario.html",
        active_page="inventario",
        telas=telas_rows,
        error=error,
        exito=exito,
    )


@app.route("/comprobantes")
@login_required
def comprobantes():
    conn_kwargs = session.get("conn_kwargs")
    error = None
    tipo_filtro = (request.args.get("tipo") or "").strip()
    filtro = (request.args.get("filtro") or "").strip().lower()

    _, comp_rows = fetch_all("sp_ListarComprobantes", (), conn_kwargs)
    if tipo_filtro in TIPOS_COMPROBANTE:
        comp_rows = [r for r in comp_rows if r[2] == tipo_filtro]
    if filtro:
        comp_rows = [
            r for r in comp_rows
            if filtro in str(r[1]).lower()
            or filtro in str(r[4]).lower()
            or filtro in str(r[5]).lower()
            or filtro in str(r[3]).lower()
        ]

    return render_template(
        "comprobantes.html",
        active_page="comprobantes",
        comprobantes=comp_rows,
        tipo_filtro=tipo_filtro,
        filtro=filtro,
        tipos_comprobante=TIPOS_COMPROBANTE,
        error=error,
    )


@app.route("/auditoria")
@login_required
def auditoria():
    conn_kwargs = session.get("conn_kwargs")
    error = None
    _, resumen_rows = fetch_all("sp_ResumenRegistros", (), conn_kwargs)
    _, audit_rows = fetch_all("sp_ListarAuditoria", (), conn_kwargs)
    return render_template(
        "auditoria.html",
        active_page="auditoria",
        resumen=resumen_rows,
        auditoria=audit_rows,
        error=error,
    )


if __name__ == "__main__":
    app.run(debug=True, port=5000)