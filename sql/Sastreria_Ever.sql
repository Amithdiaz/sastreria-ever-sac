-- ============================================================================
-- PROYECTO: GESTIÓN INTEGRAL DE PEDIDOS, CONFECCIÓN Y FACTURACIÓN
-- EMPRESA: SASTRERÍA EVER S.A.C.
-- MOTOR: SQL SERVER
-- ============================================================================

USE master;
GO

IF DB_ID('SastreriaEverDB') IS NOT NULL
BEGIN
    ALTER DATABASE SastreriaEverDB SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE SastreriaEverDB;
END;
GO

CREATE DATABASE SastreriaEverDB;
GO

USE SastreriaEverDB;
GO

-- ============================================================================
-- 1. CREACIÓN DE TABLAS
-- ============================================================================

CREATE TABLE Clientes (
    IdCliente INT IDENTITY(1,1) PRIMARY KEY,
    TipoDoc VARCHAR(10) NOT NULL CHECK (TipoDoc IN ('DNI', 'RUC', 'CE')),
    NumDoc VARCHAR(11) NOT NULL UNIQUE,
    NombresApellidos VARCHAR(120) NOT NULL,
    Telefono VARCHAR(15) NULL,
    Direccion VARCHAR(150) NULL,
    FechaRegistro DATETIME NOT NULL DEFAULT GETDATE()
);
GO

CREATE TABLE Telas_Inventario (
    IdTela INT IDENTITY(1,1) PRIMARY KEY,
    CodigoTela VARCHAR(20) NOT NULL UNIQUE,
    NombreTela VARCHAR(80) NOT NULL,
    Color VARCHAR(30) NOT NULL,
    PrecioPorMetro DECIMAL(10,2) NOT NULL CHECK (PrecioPorMetro > 0),
    StockMetros DECIMAL(10,2) NOT NULL CHECK (StockMetros >= 0),
    Estado BIT NOT NULL DEFAULT 1
);
GO

CREATE TABLE Pedidos (
    IdPedido INT IDENTITY(1,1) PRIMARY KEY,
    IdCliente INT NOT NULL FOREIGN KEY REFERENCES Clientes(IdCliente),
    IdTela INT NOT NULL FOREIGN KEY REFERENCES Telas_Inventario(IdTela),
    TipoPrenda VARCHAR(50) NOT NULL CHECK (TipoPrenda IN ('Terno', 'Saco', 'Pantalón', 'Chaleco', 'Camisa')),
    TipoCorte VARCHAR(30) NOT NULL CHECK (TipoCorte IN ('Slim Fit', 'Clásico', 'Regular', 'Entallado')),
    MetrosRequeridos DECIMAL(10,2) NOT NULL CHECK (MetrosRequeridos > 0),
    Subtotal DECIMAL(10,2) NOT NULL CHECK (Subtotal >= 0),
    EstadoConfeccion VARCHAR(25) NOT NULL DEFAULT 'Pendiente'
        CHECK (EstadoConfeccion IN ('Pendiente', 'En Corte', 'En Confección', 'En Prueba', 'Terminado', 'Entregado', 'Anulado')),
    FechaPedido DATE NOT NULL DEFAULT CAST(GETDATE() AS DATE),
    FechaEntrega DATE NOT NULL
);
GO

CREATE TABLE Medidas_Prenda (
    IdMedida INT IDENTITY(1,1) PRIMARY KEY,
    IdPedido INT NOT NULL UNIQUE FOREIGN KEY REFERENCES Pedidos(IdPedido),
    LargoSaco DECIMAL(5,2) NULL,
    Pecho DECIMAL(5,2) NULL,
    Cintura DECIMAL(5,2) NULL,
    Hombros DECIMAL(5,2) NULL,
    LargoManga DECIMAL(5,2) NULL,
    LargoPantalon DECIMAL(5,2) NULL,
    Observaciones VARCHAR(200) NULL
);
GO

CREATE TABLE Comprobantes (
    IdComprobante INT IDENTITY(1,1) PRIMARY KEY,
    IdPedido INT NOT NULL UNIQUE FOREIGN KEY REFERENCES Pedidos(IdPedido),
    TipoComprobante VARCHAR(15) NOT NULL CHECK (TipoComprobante IN ('Boleta', 'Factura')),
    SerieNumero VARCHAR(20) NOT NULL UNIQUE,
    Subtotal DECIMAL(10,2) NOT NULL,
    IGV DECIMAL(10,2) NOT NULL,
    TotalPagar DECIMAL(10,2) NOT NULL,
    MedioPago VARCHAR(25) NOT NULL CHECK (MedioPago IN ('Efectivo', 'Yape', 'Plin', 'Tarjeta', 'Transferencia')),
    FechaEmision DATETIME NOT NULL DEFAULT GETDATE()
);
GO

CREATE TABLE Auditoria_Pedidos (
    IdAuditoria INT IDENTITY(1,1) PRIMARY KEY,
    IdPedido INT NOT NULL,
    Accion VARCHAR(25) NOT NULL,
    EstadoAnterior VARCHAR(30) NULL,
    EstadoNuevo VARCHAR(30) NULL,
    UsuarioSQL VARCHAR(50) NOT NULL,
    FechaHora DATETIME NOT NULL DEFAULT GETDATE()
);
GO

USE SastreriaEverDB;
GO

ALTER TABLE Auditoria_Pedidos
ADD CONSTRAINT FK_Auditoria_Pedidos
FOREIGN KEY (IdPedido)
REFERENCES Pedidos(IdPedido);
GO

-- ============================================================================
-- 2. ÍNDICES PARA BÚSQUEDAS, CONSULTAS Y LLAVES FORÁNEAS
-- ============================================================================
CREATE INDEX IX_Clientes_NombresApellidos ON Clientes(NombresApellidos);
CREATE INDEX IX_Pedidos_IdCliente ON Pedidos(IdCliente);
CREATE INDEX IX_Pedidos_IdTela ON Pedidos(IdTela);
CREATE INDEX IX_Pedidos_EstadoConfeccion ON Pedidos(EstadoConfeccion);
CREATE INDEX IX_Comprobantes_FechaEmision ON Comprobantes(FechaEmision);
CREATE INDEX IX_Auditoria_Pedidos_IdPedido ON Auditoria_Pedidos(IdPedido);
GO

-- ============================================================================
-- 3. FUNCIÓN ESCALAR PARA CÁLCULO DE IGV (18%)
-- ============================================================================
CREATE FUNCTION dbo.fn_CalcularIGV (@Subtotal DECIMAL(10,2))
RETURNS DECIMAL(10,2)
AS
BEGIN
    RETURN ROUND(@Subtotal * 0.18, 2);
END;
GO

-- ============================================================================
-- 4. TRIGGERS (DESCUENTO AGRUPADO/REPOSICIÓN DE STOCK Y AUDITORÍA)
-- ============================================================================
CREATE TRIGGER trg_DescontarStockTela
ON Pedidos
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM Telas_Inventario t
        INNER JOIN (
            SELECT IdTela, SUM(MetrosRequeridos) AS TotalMetros
            FROM inserted
            GROUP BY IdTela
        ) req ON t.IdTela = req.IdTela
        WHERE t.StockMetros < req.TotalMetros
    )
    BEGIN
        RAISERROR('Stock insuficiente en inventario para confeccionar el pedido.', 16, 1);
        ROLLBACK TRANSACTION;
        RETURN;
    END

    UPDATE t
    SET t.StockMetros = t.StockMetros - req.TotalMetros
    FROM Telas_Inventario t
    INNER JOIN (
        SELECT IdTela, SUM(MetrosRequeridos) AS TotalMetros
        FROM inserted
        GROUP BY IdTela
    ) req ON t.IdTela = req.IdTela;
END;
GO

CREATE TRIGGER trg_ReponerStockAnulacion
ON Pedidos
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (
        SELECT 1
        FROM inserted i
        INNER JOIN deleted d ON i.IdPedido = d.IdPedido
        WHERE i.EstadoConfeccion = 'Anulado'
          AND d.EstadoConfeccion <> 'Anulado'
    )
    BEGIN
        UPDATE t
        SET t.StockMetros = t.StockMetros + anulado.TotalMetros
        FROM Telas_Inventario t
        INNER JOIN (
            SELECT i.IdTela, SUM(i.MetrosRequeridos) AS TotalMetros
            FROM inserted i
            INNER JOIN deleted d ON i.IdPedido = d.IdPedido
            WHERE i.EstadoConfeccion = 'Anulado'
              AND d.EstadoConfeccion <> 'Anulado'
            GROUP BY i.IdTela
        ) anulado ON t.IdTela = anulado.IdTela;
    END
END;
GO

CREATE TRIGGER trg_AuditoriaPedidos
ON Pedidos
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;

    IF EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO Auditoria_Pedidos (IdPedido, Accion, EstadoAnterior, EstadoNuevo, UsuarioSQL)
        SELECT IdPedido, 'INSERT', NULL, EstadoConfeccion, SYSTEM_USER
        FROM inserted;
    END

    IF EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted)
    BEGIN
        INSERT INTO Auditoria_Pedidos (IdPedido, Accion, EstadoAnterior, EstadoNuevo, UsuarioSQL)
        SELECT i.IdPedido, 'UPDATE', d.EstadoConfeccion, i.EstadoConfeccion, SYSTEM_USER
        FROM inserted i
        INNER JOIN deleted d ON i.IdPedido = d.IdPedido
        WHERE i.EstadoConfeccion <> d.EstadoConfeccion;
    END
END;
GO

-- ============================================================================
-- 5. PROCEDIMIENTOS ALMACENADOS
-- ============================================================================
CREATE PROCEDURE sp_RegistrarCliente
    @TipoDoc VARCHAR(10), @NumDoc VARCHAR(11), @NombresApellidos VARCHAR(120),
    @Telefono VARCHAR(15) = NULL, @Direccion VARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM Clientes WHERE NumDoc = @NumDoc)
    BEGIN
        RAISERROR('Ya existe un cliente registrado con ese número de documento.', 16, 1);
        RETURN;
    END
    INSERT INTO Clientes (TipoDoc, NumDoc, NombresApellidos, Telefono, Direccion)
    VALUES (@TipoDoc, @NumDoc, @NombresApellidos, @Telefono, @Direccion);
END;
GO

CREATE PROCEDURE sp_ListarClientes @Filtro VARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SELECT IdCliente, TipoDoc, NumDoc, NombresApellidos, Telefono, Direccion, FechaRegistro
    FROM Clientes
    WHERE NumDoc LIKE '%' + @Filtro + '%' OR NombresApellidos LIKE '%' + @Filtro + '%'
    ORDER BY IdCliente DESC;
END;
GO

CREATE PROCEDURE sp_ActualizarCliente @IdCliente INT, @Telefono VARCHAR(15) = NULL, @Direccion VARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Clientes SET Telefono = @Telefono, Direccion = @Direccion WHERE IdCliente = @IdCliente;
END;
GO

CREATE PROCEDURE sp_EliminarCliente @IdCliente INT
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM Pedidos WHERE IdCliente = @IdCliente)
    BEGIN
        RAISERROR('No se puede eliminar el cliente porque tiene pedidos registrados.', 16, 1);
        RETURN;
    END
    DELETE FROM Clientes WHERE IdCliente = @IdCliente;
END;
GO

CREATE PROCEDURE sp_RegistrarTela
    @CodigoTela VARCHAR(20), @NombreTela VARCHAR(80), @Color VARCHAR(30),
    @PrecioPorMetro DECIMAL(10,2), @StockMetros DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO Telas_Inventario (CodigoTela, NombreTela, Color, PrecioPorMetro, StockMetros, Estado)
    VALUES (@CodigoTela, @NombreTela, @Color, @PrecioPorMetro, @StockMetros, 1);
END;
GO

CREATE PROCEDURE sp_ListarTelas
AS
BEGIN
    SET NOCOUNT ON;
    SELECT IdTela, CodigoTela, NombreTela, Color, PrecioPorMetro, StockMetros, Estado
    FROM Telas_Inventario WHERE Estado = 1 ORDER BY IdTela DESC;
END;
GO

CREATE PROCEDURE sp_ActualizarStockTela @IdTela INT, @MetrosAdicionales DECIMAL(10,2), @NuevoPrecio DECIMAL(10,2)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Telas_Inventario
    SET StockMetros = StockMetros + @MetrosAdicionales, PrecioPorMetro = @NuevoPrecio
    WHERE IdTela = @IdTela;
END;
GO

CREATE PROCEDURE sp_DesactivarTela @IdTela INT
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Telas_Inventario SET Estado = 0 WHERE IdTela = @IdTela;
END;
GO

CREATE PROCEDURE sp_RegistrarPedidoCompleto
    @IdCliente INT, @IdTela INT, @TipoPrenda VARCHAR(50), @TipoCorte VARCHAR(30),
    @MetrosRequeridos DECIMAL(10,2), @ManoObra DECIMAL(10,2), @FechaEntrega DATE,
    @LargoSaco DECIMAL(5,2) = NULL, @Pecho DECIMAL(5,2) = NULL, @Cintura DECIMAL(5,2) = NULL,
    @Hombros DECIMAL(5,2) = NULL, @LargoManga DECIMAL(5,2) = NULL, @LargoPantalon DECIMAL(5,2) = NULL,
    @Observaciones VARCHAR(200) = NULL, @TipoComprobante VARCHAR(15), @SerieNumero VARCHAR(20), @MedioPago VARCHAR(25)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        BEGIN TRANSACTION;

        IF @MetrosRequeridos <= 0
            RAISERROR('Los metros requeridos deben ser mayores a 0.', 16, 1);

        IF @ManoObra < 0
            RAISERROR('La mano de obra no puede ser negativa.', 16, 1);

        IF @FechaEntrega < CAST(GETDATE() AS DATE)
            RAISERROR('La fecha de entrega no puede ser anterior a la fecha actual.', 16, 1);

        IF @TipoPrenda = 'Pantalón' AND (@Cintura IS NULL OR @LargoPantalon IS NULL)
            RAISERROR('Para un Pantalón debe ingresar Cintura y Largo de Pantalón.', 16, 1);

        IF @TipoPrenda = 'Saco' AND (@LargoSaco IS NULL OR @Pecho IS NULL OR @Cintura IS NULL OR @Hombros IS NULL OR @LargoManga IS NULL)
            RAISERROR('Para un Saco debe ingresar todas las medidas superiores.', 16, 1);

        IF @TipoPrenda = 'Terno' AND (@LargoSaco IS NULL OR @Pecho IS NULL OR @Cintura IS NULL OR @Hombros IS NULL OR @LargoManga IS NULL OR @LargoPantalon IS NULL)
            RAISERROR('Para un Terno completo debe ingresar las 6 medidas corporales.', 16, 1);

        DECLARE @PrecioMetro DECIMAL(10,2);
        SELECT @PrecioMetro = PrecioPorMetro FROM Telas_Inventario WHERE IdTela = @IdTela;

        IF @PrecioMetro IS NULL
            RAISERROR('La tela seleccionada no existe.', 16, 1);

        DECLARE @Subtotal DECIMAL(10,2) = (@MetrosRequeridos * @PrecioMetro) + @ManoObra;
        DECLARE @IGV DECIMAL(10,2) = dbo.fn_CalcularIGV(@Subtotal);
        DECLARE @TotalPagar DECIMAL(10,2) = @Subtotal + @IGV;

        INSERT INTO Pedidos (IdCliente, IdTela, TipoPrenda, TipoCorte, MetrosRequeridos, Subtotal, EstadoConfeccion, FechaEntrega)
        VALUES (@IdCliente, @IdTela, @TipoPrenda, @TipoCorte, @MetrosRequeridos, @Subtotal, 'Pendiente', @FechaEntrega);

        DECLARE @NuevoIdPedido INT = SCOPE_IDENTITY();

        INSERT INTO Medidas_Prenda (IdPedido, LargoSaco, Pecho, Cintura, Hombros, LargoManga, LargoPantalon, Observaciones)
        VALUES (@NuevoIdPedido, @LargoSaco, @Pecho, @Cintura, @Hombros, @LargoManga, @LargoPantalon, @Observaciones);

        INSERT INTO Comprobantes (IdPedido, TipoComprobante, SerieNumero, Subtotal, IGV, TotalPagar, MedioPago)
        VALUES (@NuevoIdPedido, @TipoComprobante, @SerieNumero, @Subtotal, @IGV, @TotalPagar, @MedioPago);

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE PROCEDURE sp_ActualizarEstadoPedido @IdPedido INT, @NuevoEstado VARCHAR(25)
AS
BEGIN
    SET NOCOUNT ON;
    UPDATE Pedidos SET EstadoConfeccion = @NuevoEstado WHERE IdPedido = @IdPedido;
END;
GO

CREATE PROCEDURE sp_ListarPedidosDetalle @Filtro VARCHAR(100) = ''
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.IdPedido, c.NombresApellidos AS Cliente, c.NumDoc,
           t.NombreTela + ' (' + t.Color + ')' AS Tela,
           p.TipoPrenda, p.TipoCorte, p.MetrosRequeridos, p.EstadoConfeccion, p.FechaEntrega,
           comp.SerieNumero, comp.Subtotal, comp.IGV, comp.TotalPagar
    FROM Pedidos p
    INNER JOIN Clientes c ON p.IdCliente = c.IdCliente
    INNER JOIN Telas_Inventario t ON p.IdTela = t.IdTela
    INNER JOIN Comprobantes comp ON p.IdPedido = comp.IdPedido
    WHERE c.NombresApellidos LIKE '%' + @Filtro + '%'
       OR c.NumDoc LIKE '%' + @Filtro + '%'
       OR CAST(p.IdPedido AS VARCHAR(20)) LIKE '%' + @Filtro + '%'
    ORDER BY p.IdPedido DESC;
END;
GO

CREATE PROCEDURE sp_ConsultarMedidasPedido @IdPedido INT
AS
BEGIN
    SET NOCOUNT ON;
    SELECT p.IdPedido, c.NombresApellidos AS Cliente, p.TipoPrenda, p.TipoCorte,
           p.EstadoConfeccion, m.LargoSaco, m.Pecho, m.Cintura, m.Hombros,
           m.LargoManga, m.LargoPantalon, m.Observaciones
    FROM Pedidos p
    INNER JOIN Clientes c ON p.IdCliente = c.IdCliente
    INNER JOIN Medidas_Prenda m ON p.IdPedido = m.IdPedido
    WHERE p.IdPedido = @IdPedido;
END;
GO

CREATE PROCEDURE sp_ListarComprobantes
AS
BEGIN
    SET NOCOUNT ON;
    SELECT comp.IdComprobante, comp.SerieNumero, comp.TipoComprobante,
           p.IdPedido, c.NombresApellidos AS Cliente, c.NumDoc,
           comp.Subtotal, comp.IGV, comp.TotalPagar, comp.MedioPago, comp.FechaEmision
    FROM Comprobantes comp
    INNER JOIN Pedidos p ON comp.IdPedido = p.IdPedido
    INNER JOIN Clientes c ON p.IdCliente = c.IdCliente
    ORDER BY comp.IdComprobante DESC;
END;
GO

CREATE PROCEDURE sp_ListarAuditoria
AS
BEGIN
    SET NOCOUNT ON;
    SELECT TOP 200 IdAuditoria, IdPedido, Accion, EstadoAnterior, EstadoNuevo, UsuarioSQL, FechaHora
    FROM Auditoria_Pedidos
    ORDER BY IdAuditoria DESC;
END;
GO

CREATE PROCEDURE sp_ResumenRegistros
AS
BEGIN
    SET NOCOUNT ON;
    SELECT '1. Telas_Inventario' AS Tabla, COUNT(*) AS TotalRegistros FROM Telas_Inventario
    UNION ALL SELECT '2. Clientes', COUNT(*) FROM Clientes
    UNION ALL SELECT '3. Pedidos', COUNT(*) FROM Pedidos
    UNION ALL SELECT '4. Medidas_Prenda', COUNT(*) FROM Medidas_Prenda
    UNION ALL SELECT '5. Comprobantes', COUNT(*) FROM Comprobantes
    UNION ALL SELECT '6. Auditoria_Pedidos', COUNT(*) FROM Auditoria_Pedidos;
END;
GO

-- ============================================================================
-- 6. CARGA MASIVA (1,050 REGISTROS POR TABLA)
-- ============================================================================

DECLARE @t INT = 1;
DECLARE @NombreTela VARCHAR(80), @ColorTela VARCHAR(30), @PrecioTela DECIMAL(10,2), @StockTela DECIMAL(10,2);
WHILE @t <= 1050
BEGIN
    SET @NombreTela = CASE (@t % 12)
        WHEN 0 THEN 'Casimir Barrington Inglés Super 130' WHEN 1 THEN 'Lana Merino Italiana Super 120'
        WHEN 2 THEN 'Paño Lanilla Nacional Premium' WHEN 3 THEN 'Lino Belga Fresco de Verano'
        WHEN 4 THEN 'Poliviscosa Ejecutiva Antiarrugas' WHEN 5 THEN 'Casimir Príncipe de Gales'
        WHEN 6 THEN 'Algodón Pima Satinado Peruano' WHEN 7 THEN 'Tweed Escocés de Lana Pura'
        WHEN 8 THEN 'Gabardina de Algodón Peinado' WHEN 9 THEN 'Seda Fría Italiana de Gala'
        WHEN 10 THEN 'Terciopelo Fino de Etiqueta' ELSE 'Casimir Fil a Fil Importado' END;
    SET @ColorTela = CASE (@t % 11)
        WHEN 0 THEN 'Azul Marino' WHEN 1 THEN 'Negro Azabache' WHEN 2 THEN 'Gris Oxford'
        WHEN 3 THEN 'Azul Noche' WHEN 4 THEN 'Plomo Rata' WHEN 5 THEN 'Beige Arena'
        WHEN 6 THEN 'Azul Acero' WHEN 7 THEN 'Vino Borgoña' WHEN 8 THEN 'Marrón Tabaco'
        WHEN 9 THEN 'Verde Botella' ELSE 'Blanco Marfil' END;
    SET @PrecioTela = (CASE (@t % 12) WHEN 0 THEN 155.00 WHEN 1 THEN 185.00 WHEN 2 THEN 85.00 WHEN 3 THEN 115.00 WHEN 4 THEN 68.00 WHEN 5 THEN 165.00 WHEN 6 THEN 58.00 WHEN 7 THEN 195.00 WHEN 8 THEN 92.00 WHEN 9 THEN 210.00 WHEN 10 THEN 175.00 ELSE 138.00 END) + ((@t % 5) * 2.50);
    SET @StockTela = 45.00 + ((@t * 7) % 71);

    INSERT INTO Telas_Inventario (CodigoTela, NombreTela, Color, PrecioPorMetro, StockMetros, Estado)
    VALUES ('ROLL-' + RIGHT('00000' + CAST(@t AS VARCHAR), 5), @NombreTela, @ColorTela, @PrecioTela, @StockTela, 1);
    SET @t = @t + 1;
END;
GO

DECLARE @c INT = 1;
DECLARE @NombreCompleto VARCHAR(120), @DireccionReal VARCHAR(150), @TelefonoReal VARCHAR(15);
WHILE @c <= 1050
BEGIN
    SET @NombreCompleto = (CASE (@c % 13) WHEN 0 THEN 'Carlos Alberto' WHEN 1 THEN 'María Fernanda' WHEN 2 THEN 'José Luis' WHEN 3 THEN 'Ana Sofía' WHEN 4 THEN 'Juan Manuel' WHEN 5 THEN 'Lucía Valentina' WHEN 6 THEN 'Miguel Ángel' WHEN 7 THEN 'Rosa Elena' WHEN 8 THEN 'Pedro Antonio' WHEN 9 THEN 'Carmen Julia' WHEN 10 THEN 'Diego Alonso' WHEN 11 THEN 'Valeria Camila' ELSE 'Jorge Enrique' END) + ' ' + (CASE (@c % 11) WHEN 0 THEN 'Rojas' WHEN 1 THEN 'Huamán' WHEN 2 THEN 'Vargas' WHEN 3 THEN 'Mendoza' WHEN 4 THEN 'Salazar' WHEN 5 THEN 'Castillo' WHEN 6 THEN 'Torres' WHEN 7 THEN 'Quispe' WHEN 8 THEN 'Espinoza' WHEN 9 THEN 'Paredes' ELSE 'Chávez' END) + ' ' + (CASE (@c % 9) WHEN 0 THEN 'Gutiérrez' WHEN 1 THEN 'Flores' WHEN 2 THEN 'Díaz' WHEN 3 THEN 'Ramos' WHEN 4 THEN 'Morales' WHEN 5 THEN 'Castro' WHEN 6 THEN 'Ortiz' WHEN 7 THEN 'Silva' ELSE 'Reyes' END);
    SET @DireccionReal = (CASE (@c % 8) WHEN 0 THEN 'Av. Túpac Amaru ' WHEN 1 THEN 'Av. Universitaria ' WHEN 2 THEN 'Jr. Las Palmeras ' WHEN 3 THEN 'Av. Carlos Izaguirre ' WHEN 4 THEN 'Calle Los Sauces ' WHEN 5 THEN 'Av. Alfredo Mendiola ' WHEN 6 THEN 'Av. Antúnez de Mayolo ' ELSE 'Jr. Los Jazmines ' END) + CAST(100 + ((@c * 13) % 890) AS VARCHAR) + ' - ' + (CASE (@c % 7) WHEN 0 THEN 'Comas' WHEN 1 THEN 'Los Olivos' WHEN 2 THEN 'San Martín de Porres' WHEN 3 THEN 'Independencia' WHEN 4 THEN 'Carabayllo' WHEN 5 THEN 'Puente Piedra' ELSE 'San Isidro' END);
    SET @TelefonoReal = '9' + RIGHT('00000000' + CAST((14829310 + (@c * 7919)) % 89999999 + 10000000 AS VARCHAR), 8);

    INSERT INTO Clientes (TipoDoc, NumDoc, NombresApellidos, Telefono, Direccion)
    VALUES (
        CASE WHEN @c % 12 = 0 THEN 'RUC' ELSE 'DNI' END,
        CASE WHEN @c % 12 = 0 THEN '20' + RIGHT('000000000' + CAST(601234500 + @c AS VARCHAR), 9) ELSE RIGHT('00000000' + CAST(41258900 + @c AS VARCHAR), 8) END,
        @NombreCompleto, @TelefonoReal, @DireccionReal
    );
    SET @c = @c + 1;
END;
GO

DECLARE @p INT = 1;
DECLARE @ClienteId INT, @Prenda VARCHAR(50), @Corte VARCHAR(30), @Metros DECIMAL(10,2), @SubtotalPed DECIMAL(10,2);
DECLARE @PrecioTelaPed DECIMAL(10,2), @ManoObraPed DECIMAL(10,2), @FechaEntrega DATE;

WHILE @p <= 1050
BEGIN
    SET @ClienteId = ((@p * 17) % 1050) + 1;
    SET @Prenda = CASE (@p % 5) WHEN 0 THEN 'Terno' WHEN 1 THEN 'Pantalón' WHEN 2 THEN 'Saco' WHEN 3 THEN 'Chaleco' ELSE 'Camisa' END;
    SET @Corte = CASE (@p % 4) WHEN 0 THEN 'Slim Fit' WHEN 1 THEN 'Clásico' WHEN 2 THEN 'Regular' ELSE 'Entallado' END;
    SET @Metros = CASE @Prenda WHEN 'Terno' THEN 3.20 WHEN 'Saco' THEN 2.00 WHEN 'Pantalón' THEN 1.35 WHEN 'Camisa' THEN 1.60 ELSE 1.10 END;
    SET @ManoObraPed = CASE @Prenda WHEN 'Terno' THEN 240.00 WHEN 'Saco' THEN 160.00 WHEN 'Pantalón' THEN 85.00 WHEN 'Camisa' THEN 75.00 ELSE 70.00 END;
    SET @FechaEntrega = DATEADD(DAY, 7 + (@p % 20), CAST(GETDATE() AS DATE));

    SELECT @PrecioTelaPed = PrecioPorMetro FROM Telas_Inventario WHERE IdTela = @p;
    SET @SubtotalPed = (@Metros * @PrecioTelaPed) + @ManoObraPed;

    INSERT INTO Pedidos (IdCliente, IdTela, TipoPrenda, TipoCorte, MetrosRequeridos, Subtotal, EstadoConfeccion, FechaEntrega)
    VALUES (@ClienteId, @p, @Prenda, @Corte, @Metros, @SubtotalPed, 'Pendiente', @FechaEntrega);

    SET @p = @p + 1;
END;
GO

DECLARE @m INT = 1;
DECLARE @PrendaMed VARCHAR(50), @Obs VARCHAR(200);
DECLARE @LargoSaco DECIMAL(5,2), @Pecho DECIMAL(5,2), @Cintura DECIMAL(5,2), @Hombros DECIMAL(5,2), @LargoManga DECIMAL(5,2), @LargoPantalon DECIMAL(5,2);

WHILE @m <= 1050
BEGIN
    SELECT @PrendaMed = TipoPrenda FROM Pedidos WHERE IdPedido = @m;

    SET @Cintura = 78.00 + (@m % 26);
    SET @LargoSaco = CASE WHEN @PrendaMed IN ('Terno', 'Saco', 'Chaleco', 'Camisa') THEN 70.00 + (@m % 9) ELSE NULL END;
    SET @Pecho = CASE WHEN @PrendaMed IN ('Terno', 'Saco', 'Chaleco', 'Camisa') THEN 92.00 + (@m % 20) ELSE NULL END;
    SET @Hombros = CASE WHEN @PrendaMed IN ('Terno', 'Saco', 'Camisa') THEN 42.00 + (@m % 8) ELSE NULL END;
    SET @LargoManga = CASE WHEN @PrendaMed IN ('Terno', 'Saco', 'Camisa') THEN 59.00 + (@m % 7) ELSE NULL END;
    SET @LargoPantalon = CASE WHEN @PrendaMed IN ('Terno', 'Pantalón') THEN 96.00 + (@m % 12) ELSE NULL END;

    SET @Obs = CASE (@m % 6)
        WHEN 0 THEN 'Solapa en punta con forro satinado interior'
        WHEN 1 THEN 'Pantalón sin pinzas con basta inglesa'
        WHEN 2 THEN 'Cintura ligeramente entallada para evento formal'
        WHEN 3 THEN 'Botones nacarados y bolsillo oculto interior'
        WHEN 4 THEN 'Prueba intermedia programada 5 días antes'
        ELSE 'Acabado estándar de sastrería a medida'
    END;

    INSERT INTO Medidas_Prenda (IdPedido, LargoSaco, Pecho, Cintura, Hombros, LargoManga, LargoPantalon, Observaciones)
    VALUES (@m, @LargoSaco, @Pecho, @Cintura, @Hombros, @LargoManga, @LargoPantalon, @Obs);

    SET @m = @m + 1;
END;
GO

DECLARE @f INT = 1;
DECLARE @SubComp DECIMAL(10,2), @IgvComp DECIMAL(10,2), @TotComp DECIMAL(10,2);
DECLARE @TipoComp VARCHAR(15), @Serie VARCHAR(20), @MedioPago VARCHAR(25);

WHILE @f <= 1050
BEGIN
    SELECT @SubComp = Subtotal FROM Pedidos WHERE IdPedido = @f;
    SET @IgvComp = dbo.fn_CalcularIGV(@SubComp);
    SET @TotComp = @SubComp + @IgvComp;

    SET @TipoComp = CASE WHEN @f % 8 = 0 THEN 'Factura' ELSE 'Boleta' END;
    SET @Serie = CASE WHEN @TipoComp = 'Factura'
        THEN 'F001-' + RIGHT('000000' + CAST(@f AS VARCHAR), 6)
        ELSE 'B001-' + RIGHT('000000' + CAST(@f AS VARCHAR), 6)
    END;

    SET @MedioPago = CASE (@f % 5)
        WHEN 0 THEN 'Yape' WHEN 1 THEN 'Efectivo' WHEN 2 THEN 'Tarjeta' WHEN 3 THEN 'Plin' ELSE 'Transferencia' END;

    INSERT INTO Comprobantes (IdPedido, TipoComprobante, SerieNumero, Subtotal, IGV, TotalPagar, MedioPago)
    VALUES (@f, @TipoComp, @Serie, @SubComp, @IgvComp, @TotComp, @MedioPago);

    SET @f = @f + 1;
END;
GO

DECLARE @a INT = 1;
WHILE @a <= 1050
BEGIN
    IF @a % 4 = 0
        EXEC sp_ActualizarEstadoPedido @IdPedido = @a, @NuevoEstado = 'Entregado';
    ELSE IF @a % 4 = 1
        EXEC sp_ActualizarEstadoPedido @IdPedido = @a, @NuevoEstado = 'Terminado';
    ELSE IF @a % 4 = 2
        EXEC sp_ActualizarEstadoPedido @IdPedido = @a, @NuevoEstado = 'En Confección';

    SET @a = @a + 1;
END;
GO

-- ============================================================================
-- 7. VERIFICACIÓN DE REGISTROS
-- ============================================================================
EXEC dbo.sp_ResumenRegistros;
GO