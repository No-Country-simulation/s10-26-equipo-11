-- =============================================================================
-- UXFlow – Carga de Desafíos
-- Esquema inicial de base de datos (v1, MVP) – PostgreSQL 13+
-- =============================================================================
--
-- Flujo que soporta este esquema:
--   1. Dashboard público sin autenticación, con datos reales de la simulación
--      actual sincronizados desde la web pública de No Country.
--   2. Inicio de sesión del decisor con Google o magic link, implementado por
--      el backend propio. Brevo solo envía los emails. El email se persiste
--      apenas el decisor lo ingresa.
--   3. Datos del decisor: nombre, perfil y organización (obligatorios en la
--      aplicación antes de enviar) y teléfono (opcional).
--   4. Carga del desafío por formulario (variantes A/B) o por llamada: el
--      decisor la pide y un admin la coordina desde el panel (fecha, horario y
--      link de la videollamada), sin servicios de agenda externos.
--   5. Revisión, pedido de contexto y aprobación desde el panel de admin, con
--      acceso por email y contraseña.
--
-- Criterio del MVP: cada tabla y columna sostiene una parte del flujo o una
-- métrica que pide el documento de No Country (Piezas 1 a 6). Lo demás se
-- agrega por migración cuando haga falta.
--
-- Despliegue: PostgreSQL en Supabase, usado solo como base de datos. RLS queda
-- activado en todas las tablas (ver el final del script).
--
-- Convenciones:
--   * Identificadores en inglés, snake_case y en minúsculas.
--   * Tablas en plural. Clave primaria: id. Claves foráneas: <entidad>_id.
--   * Fechas y horas: timestamptz con sufijo _at. Fechas sin hora: date con _on.
--   * Valores de estados y tipos en MAYÚSCULAS, como text + CHECK (no ENUM).
--   * Códigos e identificadores técnicos (form_variants.code,
--     tracking_events.event_name) en minúsculas snake_case.
--   * Tokens y contraseñas se guardan solo como hash, nunca en texto plano.
--
-- Pieza 6: el email de aprobación se mide con email_messages y tracking_events.
-- Qué quiere ver el decisor mientras su desafío está activo (progreso del
-- equipo, actividad, entregables parciales) se testea con prototipos: en este
-- proyecto ningún equipo ejecuta los desafíos, así que no hay progreso real
-- que guardar.
--
-- Fuera de esta versión (se agregan por migración si hacen falta):
--   * Roles distintos dentro del panel de admin y sesiones revocables.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Función común: mantiene updated_at al día
-- -----------------------------------------------------------------------------
CREATE
OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at
:= now();
RETURN NEW;
END;
$$;

-- -----------------------------------------------------------------------------
-- simulations: encabezado de la simulación que muestra el dashboard público
-- Se sincroniza desde la web pública de No Country. Si la simulación está activa
-- se deriva de las fechas. `synced_at` indica la última sincronización exitosa.
-- -----------------------------------------------------------------------------
CREATE TABLE simulations
(
    id               uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    name             text        NOT NULL,
    starts_on        date        NOT NULL,
    ends_on          date        NOT NULL,
    demo_day_on      date,
    registrant_count integer     NOT NULL DEFAULT 0,
    country_count    integer     NOT NULL DEFAULT 0,
    synced_at        timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_simulations_dates
        CHECK (ends_on >= starts_on),
    CONSTRAINT ck_simulations_demo_day
        CHECK (demo_day_on IS NULL OR demo_day_on BETWEEN starts_on AND ends_on),
    CONSTRAINT ck_simulations_counts
        CHECK (registrant_count >= 0 AND country_count >= 0)
);

-- -----------------------------------------------------------------------------
-- simulation_projects: proyectos activos del dashboard público (Pieza 1)
-- Una fila por proyecto con conteos agregados; sin datos de equipos ni personas.
-- Cada sincronización reemplaza los proyectos de la simulación.
-- -----------------------------------------------------------------------------
CREATE TABLE simulation_projects
(
    id                uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    simulation_id     uuid        NOT NULL,
    name              text        NOT NULL,
    category          text, -- vertical en No Country (Cloud, Cybersecurity, ...)
    team_count        integer     NOT NULL DEFAULT 0,
    participant_count integer     NOT NULL DEFAULT 0,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_simulation_projects_simulation
        FOREIGN KEY (simulation_id) REFERENCES simulations (id) ON DELETE CASCADE,
    CONSTRAINT uq_simulation_projects_simulation_id_name UNIQUE (simulation_id, name),
    CONSTRAINT ck_simulation_projects_counts
        CHECK (team_count >= 0 AND participant_count >= 0)
);

-- -----------------------------------------------------------------------------
-- form_variants: variantes del formulario de carga (Pieza 2)
-- Cada fila es una variante (code: 'free_text', 'guided'). `is_active` define qué
-- variantes se asignan a los decisores nuevos.
--
-- `field_schema` define los campos del formulario en esa variante. Todas las
-- variantes empiezan con el campo "title" (título del desafío), así se
-- autoguarda como cualquier otro campo; al enviar, el backend copia
-- answers.title a challenges.title. Los datos del decisor no van acá: son
-- columnas de decision_makers.
--   {
--     "fields": [
--       {
--         "key":        "problem", -- clave en answers y en last_field_key
--         "type":       "textarea", -- 'text' | 'textarea'
--         "label":      "¿Cuál es el problema?", -- texto visible
--         "help": "Cuéntalo con tus palabras.", -- opcional, texto de ayuda
--         "required": true,
--         "max_length": 2000
--       }
--     ]
--   }
-- El frontend dibuja los campos en ese orden. El backend valída `answers` con
-- las mismas reglas (obligatorios, largo máximo, claves permitidas).
-- -----------------------------------------------------------------------------
CREATE TABLE form_variants
(
    id           uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    code         text        NOT NULL,
    name         text        NOT NULL,
    field_schema jsonb       NOT NULL,
    is_active    boolean     NOT NULL DEFAULT true,
    created_at   timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_form_variants_code UNIQUE (code),
    CONSTRAINT ck_form_variants_code CHECK (code ~ '^[a-z][a-z0-9_]*$'
) ,
    -- Forma mínima: un objeto con una lista "fields" de al menos un campo
    -- CASE: si falta "fields", la condición da false (no NULL, que el CHECK aceptaría)
    CONSTRAINT ck_form_variants_field_schema CHECK (
        CASE WHEN jsonb_typeof(field_schema -> 'fields') = 'array'
             THEN jsonb_array_length(field_schema -> 'fields') >= 1
             ELSE false
        END
    )
);

-- -----------------------------------------------------------------------------
-- admin_users: equipo que revisa y aprueba desafíos y atiende llamadas
-- Acceso al panel con email y contraseña (hash bcrypt o argon2). En el MVP
-- todos tienen los mismos permisos. Los usuarios se crean por script.
-- -----------------------------------------------------------------------------
CREATE TABLE admin_users
(
    id            uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    email         text        NOT NULL,
    password_hash text        NOT NULL,
    full_name     text        NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX uq_admin_users_email ON admin_users (lower(email));

-- -----------------------------------------------------------------------------
-- decision_makers: decisores que cargan desafíos
-- La fila se crea cuando el decisor ingresa su email (magic link) o entra con
-- Google, antes de conocer su nombre. Por eso full_name, profile_type y
-- organization_name aceptan NULL: la aplicación los exige antes de enviar.
-- `email_verified_at` se completa al usar el primer link o al entrar con Google.
-- `google_sub` no nulo = el decisor entró alguna vez con Google.
-- `timezone` es la zona horaria IANA del decisor (p. ej., 'America/Mexico_City'),
-- informada por el navegador. Se usa para mostrarle la fecha y hora de sus
-- llamadas en su hora local. El backend la valída antes de guardarla.
-- Los emails de recuperación solo se envían si consent_accepted_at no es nulo.
-- -----------------------------------------------------------------------------
CREATE TABLE decision_makers
(
    id                  uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    email               text        NOT NULL,
    email_verified_at   timestamptz,
    google_sub          text, -- id fijo de la cuenta de Google
    full_name           text,
    profile_type        text,
    organization_name   text,
    phone               text,
    timezone            text,
    consent_accepted_at timestamptz,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT ck_decision_makers_profile_type CHECK (
        profile_type IN ('TEACHER', 'TECH_LEAD', 'FOUNDER', 'SENIOR_PROFESSIONAL', 'OTHER')
        ),
    -- Largos: rechazan textos vacíos o con solo espacios y textos excesivos
    CONSTRAINT ck_decision_makers_full_name_length
        CHECK (char_length(btrim(full_name)) BETWEEN 1 AND 120),
    CONSTRAINT ck_decision_makers_organization_name_length
        CHECK (char_length(btrim(organization_name)) BETWEEN 1 AND 150),
    CONSTRAINT ck_decision_makers_phone_length
        CHECK (char_length(btrim(phone)) BETWEEN 1 AND 30),
    CONSTRAINT ck_decision_makers_timezone_length
        CHECK (char_length(timezone) BETWEEN 1 AND 64)
);

CREATE UNIQUE INDEX uq_decision_makers_email ON decision_makers (lower(email));
CREATE UNIQUE INDEX uq_decision_makers_google_sub
    ON decision_makers (google_sub) WHERE google_sub IS NOT NULL;

-- -----------------------------------------------------------------------------
-- magic_link_tokens: links de inicio de sesión enviados al decisor
-- Se guarda solo el hash (SHA-256) del token. Cada link es de un solo uso y
-- vence a los pocos minutos. Validación y consumo en una sola consulta:
--   UPDATE ... SET used_at = now() WHERE token_hash = $1
--   AND used_at IS NULL AND expires_at > now() RETURNING decision_maker_id
-- -----------------------------------------------------------------------------
CREATE TABLE magic_link_tokens
(
    id                uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    decision_maker_id uuid        NOT NULL,
    token_hash        text        NOT NULL,
    expires_at        timestamptz NOT NULL,
    used_at           timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_magic_link_tokens_decision_maker
        FOREIGN KEY (decision_maker_id) REFERENCES decision_makers (id) ON DELETE CASCADE,
    CONSTRAINT uq_magic_link_tokens_token_hash UNIQUE (token_hash),
    CONSTRAINT ck_magic_link_tokens_expires CHECK (expires_at > created_at)
);

-- Límite de pedidos: links recientes por decisor
CREATE INDEX idx_magic_link_tokens_decision_maker_id
    ON magic_link_tokens (decision_maker_id, created_at);

-- -----------------------------------------------------------------------------
-- form_sessions: cada intento de completar el formulario
-- Guarda la variante asignada (A/B), el borrador y el último campo tocado.
-- Sin completed_at y sin actividad reciente = abandono (Pieza 4).
-- La variante se mantiene para el decisor buscando su sesión anterior.
-- -----------------------------------------------------------------------------
CREATE TABLE form_sessions
(
    id                uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    decision_maker_id uuid        NOT NULL,
    form_variant_id   uuid        NOT NULL,
    partial_answers   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    last_field_key    text, -- en qué campo abandona o duda (Pieza 2)
    last_activity_at  timestamptz NOT NULL DEFAULT now(),
    completed_at      timestamptz,
    created_at        timestamptz NOT NULL DEFAULT now(),
    updated_at        timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_form_sessions_decision_maker
        FOREIGN KEY (decision_maker_id) REFERENCES decision_makers (id) ON DELETE CASCADE,
    CONSTRAINT fk_form_sessions_form_variant
        FOREIGN KEY (form_variant_id) REFERENCES form_variants (id) ON DELETE RESTRICT,
    CONSTRAINT ck_form_sessions_completed
        CHECK (completed_at IS NULL OR completed_at >= created_at)
);

CREATE INDEX idx_form_sessions_decision_maker_id ON form_sessions (decision_maker_id);

-- -----------------------------------------------------------------------------
-- challenges: desafíos enviados
-- answers guarda las respuestas finales con las claves del field_schema de la
-- variante (incluido "title"). `title` es una copia de `answers.title` para listar
-- y ordenar sin leer el JSON.
-- `source` indica cómo llegó el desafío:
--   * 'FORM': lo cargó el decisor con el formulario (tiene form_session_id,
--                y por esa sesión, su variante).
--   * 'MEETING': lo cargó el equipo a partir de una llamada (queda fuera de la
--                comparación A/B).
--
-- Estados (el backend controla las transiciones):
--   SUBMITTED → IN_REVIEW → APPROVED
--                         → REJECTED → (el decisor modifica) SUBMITTED
--                         → CONTEXT_REQUESTED → (el decisor modifica) SUBMITTED
-- En REJECTED y CONTEXT_REQUESTED, el decisor puede modificar y reenviar,
-- pedir una llamada (meetings, purpose 'REVIEW_FOLLOW_UP'), o ambas cosas.
-- `review_feedback` le explica qué cambiar o qué falta.
--
-- `submitted_at` es la fecha del último envío (la que ve el decisor en su
-- listado) y submission_count cuántas veces lo envió. Con submitted_at y
-- reviewed_at se mide el tiempo de respuesta de cada ronda (Pieza 3).
-- `quality_score` es la calificación vigente del revisor (cambia en cada revisión).
-- `initial_quality_score` es la calificación de la primera revisión y no cambia:
-- con ella se compara qué variante genera descripciones de mayor calidad
-- (Pieza 2), sin el sesgo de las correcciones posteriores. El backend la
-- completa con: initial_quality_score = COALESCE(initial_quality_score, $1)
-- simulation_id es la simulación a la que el equipo asigna el desafío aprobado.
-- -----------------------------------------------------------------------------
CREATE TABLE challenges
(
    id                    uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    decision_maker_id     uuid        NOT NULL,
    source                text        NOT NULL DEFAULT 'FORM',
    form_session_id       uuid,
    simulation_id         uuid,
    title                 text        NOT NULL,
    answers               jsonb       NOT NULL DEFAULT '{}'::jsonb,
    status                text        NOT NULL DEFAULT 'SUBMITTED',
    quality_score         smallint,                                        -- 1 a 5, vigente
    initial_quality_score smallint,                                        -- 1 a 5, primera revisión
    review_feedback       text,                                            -- visible para el decisor
    submission_count      smallint    NOT NULL DEFAULT 1,
    submitted_at          timestamptz NOT NULL DEFAULT now(),
    reviewed_at           timestamptz,
    created_at            timestamptz NOT NULL DEFAULT now(),
    updated_at            timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_challenges_decision_maker
        FOREIGN KEY (decision_maker_id) REFERENCES decision_makers (id) ON DELETE RESTRICT,
    CONSTRAINT fk_challenges_form_session
        FOREIGN KEY (form_session_id) REFERENCES form_sessions (id) ON DELETE RESTRICT,
    CONSTRAINT fk_challenges_simulation
        FOREIGN KEY (simulation_id) REFERENCES simulations (id) ON DELETE SET NULL,
    CONSTRAINT uq_challenges_form_session_id UNIQUE (form_session_id),
    CONSTRAINT ck_challenges_source
        CHECK (source IN ('FORM', 'MEETING')),
    CONSTRAINT ck_challenges_form_session
        CHECK (source <> 'FORM' OR form_session_id IS NOT NULL),
    CONSTRAINT ck_challenges_status CHECK (status IN (
                                                      'SUBMITTED',         -- enviado, pendiente de revisión
                                                      'IN_REVIEW',         -- en revisión por el equipo
                                                      'CONTEXT_REQUESTED', -- falta contexto (Pieza 5)
                                                      'APPROVED',          -- aprobado
                                                      'REJECTED'           -- rechazado; el decisor puede modificar y reenviar
        )),
    CONSTRAINT ck_challenges_quality_score
        CHECK (quality_score BETWEEN 1 AND 5),
    CONSTRAINT ck_challenges_initial_quality_score
        CHECK (initial_quality_score BETWEEN 1 AND 5),
    CONSTRAINT ck_challenges_title_length
        CHECK (char_length(btrim(title)) BETWEEN 1 AND 150),
    CONSTRAINT ck_challenges_submission_count
        CHECK (submission_count >= 1),
    CONSTRAINT ck_challenges_reviewed
        CHECK (status NOT IN ('APPROVED', 'REJECTED', 'CONTEXT_REQUESTED') OR reviewed_at IS NOT NULL),
    CONSTRAINT ck_challenges_review_feedback
        CHECK (status NOT IN ('REJECTED', 'CONTEXT_REQUESTED') OR review_feedback IS NOT NULL),
    CONSTRAINT ck_challenges_simulation
        CHECK (simulation_id IS NULL OR status = 'APPROVED')
);

CREATE INDEX idx_challenges_decision_maker_id ON challenges (decision_maker_id);
CREATE INDEX idx_challenges_status ON challenges (status);

COMMENT
ON COLUMN challenges.initial_quality_score IS
  'Calidad de la primera versión (1 a 5): 1 = no se entiende el problema; '
  '2 = falta a quién afecta o qué resultado espera; 3 = falta contexto para empezar; '
  '4 = alcanza con alguna pregunta menor; 5 = un equipo puede empezar sin preguntas.';

-- -----------------------------------------------------------------------------
-- meetings: llamadas con el decisor, coordinadas desde el panel de admin
-- Flujo:
--   1. El decisor (con nombre, perfil y organización completos) pide una
--      llamada y elige en un calendario de 1 a 3 fechas y horas posibles
--      (proposed_slots), en su hora local. Puede sumar un comentario
--      (availability_notes). La fila se crea con status 'REQUESTED' y se avisa
--      a los admins. Que las opciones sean futuras lo valida el backend.
--   2. Un admin elige la solicitud en el panel, confirma una de las opciones (o
--      propone otra) en scheduled_for y carga el link de la videollamada
--      (meeting_url: Zoom, Meet, Teams...). Pasa a 'SCHEDULED' y se envía el
--      email MEETING_SCHEDULED al decisor (en su timezone) y a los admins.
--   3. Si el decisor no puede en ese horario, propone nuevas opciones y vuelve
--      a 'REQUESTED'. El backend limpia scheduled_for y meeting_url.
--   4. Después de la llamada, el admin la marca 'COMPLETED' y escribe notes.
--      Si fue 'DESCRIBE_CHALLENGE', carga el desafío (source 'MEETING') y lo
--      vincula en challenge_id. 'CANCELLED' si no se realiza.
-- Pueden existir sin desafío ('LEARN_MORE', o 'DESCRIBE_CHALLENGE' antes de
-- cargarlo). 'REVIEW_FOLLOW_UP' siempre tiene desafío: por eso un desafío con
-- una llamada de seguimiento no se puede borrar sin desvincularla antes.
-- -----------------------------------------------------------------------------
CREATE TABLE meetings
(
    id                 uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    decision_maker_id  uuid        NOT NULL,
    challenge_id       uuid,
    purpose            text        NOT NULL,
    status             text        NOT NULL DEFAULT 'REQUESTED',
    proposed_slots     timestamptz[],                                       -- 1 a 3 fechas y horas que propone el decisor
    availability_notes text,                                                -- comentario opcional del decisor
    scheduled_for      timestamptz,                                         -- lo completa el admin
    meeting_url        text,                                                -- lo completa el admin
    notes              text,                                                -- qué se habló, lo completa el admin
    created_at         timestamptz NOT NULL DEFAULT now(),
    updated_at         timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_meetings_decision_maker
        FOREIGN KEY (decision_maker_id) REFERENCES decision_makers (id) ON DELETE CASCADE,
    CONSTRAINT fk_meetings_challenge
        FOREIGN KEY (challenge_id) REFERENCES challenges (id) ON DELETE SET NULL,
    CONSTRAINT ck_meetings_purpose CHECK (purpose IN (
                                                      'DESCRIBE_CHALLENGE', -- el decisor prefiere contar su desafío en una llamada
                                                      'LEARN_MORE',         -- el decisor quiere saber más sobre la propuesta
                                                      'REVIEW_FOLLOW_UP'    -- desafío rechazado o con contexto pedido (Pieza 5)
        )),
    CONSTRAINT ck_meetings_status CHECK (status IN (
                                                    'REQUESTED',            -- pedida por el decisor, sin fecha todavía
                                                    'SCHEDULED',            -- con fecha, hora y link
                                                    'COMPLETED',            -- realizada
                                                    'CANCELLED'             -- no se realiza
        )),
    CONSTRAINT ck_meetings_review_follow_up
        CHECK (purpose <> 'REVIEW_FOLLOW_UP' OR challenge_id IS NOT NULL),
    -- Una llamada agendada o realizada siempre tiene fecha y link
    CONSTRAINT ck_meetings_scheduled
        CHECK (status NOT IN ('SCHEDULED', 'COMPLETED')
            OR (scheduled_for IS NOT NULL AND meeting_url IS NOT NULL)),
    CONSTRAINT ck_meetings_meeting_url
        CHECK (meeting_url ~ '^https://'
) ,
    -- Entre 1 y 3 opciones, sin valores vacíos dentro de la lista
    -- (cardinality y no array_length: con una lista vacía devuelve 0, no NULL)
    CONSTRAINT ck_meetings_proposed_slots
        CHECK (cardinality(proposed_slots) BETWEEN 1 AND 3
               AND array_position(proposed_slots, NULL) IS NULL),
    -- Una solicitud pendiente siempre tiene al menos una opción propuesta
    CONSTRAINT ck_meetings_requested
        CHECK (status <> 'REQUESTED' OR proposed_slots IS NOT NULL),
    CONSTRAINT ck_meetings_availability_notes_length
        CHECK (char_length(availability_notes) <= 500)
);

CREATE INDEX idx_meetings_decision_maker_id ON meetings (decision_maker_id);
-- Solicitudes pendientes del panel de admin
CREATE INDEX idx_meetings_requested
    ON meetings (created_at) WHERE status = 'REQUESTED';

-- -----------------------------------------------------------------------------
-- email_messages: emails del flujo (magic link y Piezas 3, 4, 5 y 6)
-- Un email por cada cambio de estado que el decisor necesita conocer:
-- IN_REVIEW → REVIEW_STARTED, APPROVED → APPROVAL, REJECTED → REJECTION,
-- CONTEXT_REQUESTED → CONTEXT_REQUEST (con la opción de pedir una llamada),
-- asignación de simulación → SIMULATION_ASSIGNED y llamada agendada →
-- MEETING_SCHEDULED (con meeting_id: fecha, hora en la timezone del decisor y
-- link). Los avisos a los admins no se registran acá: esta tabla guarda solo
-- los emails que recibe el decisor, que son los que se miden.
-- `variant_code` identifica la versión de copy o timing que se está testeando.
-- `status` 'SCHEDULED' + `scheduled_for` funcionan como cola: así se programan los
-- emails de recuperación con distintos tiempos de espera (Pieza 4).
-- El webhook de Brevo busca la fila por provider_message_id y completa
-- first_opened_at y first_clicked_at, o marca 'FAILED' si el email rebotó.
-- -----------------------------------------------------------------------------
CREATE TABLE email_messages
(
    id                  uuid PRIMARY KEY     DEFAULT gen_random_uuid(),
    decision_maker_id   uuid        NOT NULL,
    challenge_id        uuid,
    form_session_id     uuid, -- emails de recuperación de abandono
    meeting_id          uuid, -- emails de llamada agendada
    email_type          text        NOT NULL,
    variant_code        text,
    provider_message_id text, -- messageId que devuelve Brevo
    status              text        NOT NULL DEFAULT 'SCHEDULED',
    scheduled_for       timestamptz NOT NULL DEFAULT now(),
    sent_at             timestamptz,
    first_opened_at     timestamptz,
    first_clicked_at    timestamptz,
    error_message       text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_email_messages_decision_maker
        FOREIGN KEY (decision_maker_id) REFERENCES decision_makers (id) ON DELETE CASCADE,
    CONSTRAINT fk_email_messages_challenge
        FOREIGN KEY (challenge_id) REFERENCES challenges (id) ON DELETE SET NULL,
    CONSTRAINT fk_email_messages_form_session
        FOREIGN KEY (form_session_id) REFERENCES form_sessions (id) ON DELETE SET NULL,
    CONSTRAINT fk_email_messages_meeting
        FOREIGN KEY (meeting_id) REFERENCES meetings (id) ON DELETE SET NULL,
    CONSTRAINT uq_email_messages_provider_message_id UNIQUE (provider_message_id),
    CONSTRAINT ck_email_messages_email_type CHECK (email_type IN (
                                                                  'MAGIC_LINK',
                                                                  'SUBMISSION_CONFIRMATION',
                                                                  'ABANDONMENT_RECOVERY',
                                                                  'REVIEW_STARTED',
                                                                  'CONTEXT_REQUEST',
                                                                  'APPROVAL',
                                                                  'REJECTION',
                                                                  'SIMULATION_ASSIGNED',
                                                                  'MEETING_SCHEDULED'
        )),
    CONSTRAINT ck_email_messages_status
        CHECK (status IN ('SCHEDULED', 'SENT', 'FAILED', 'CANCELLED'))
);

-- Cola de envíos programados
CREATE INDEX idx_email_messages_scheduled
    ON email_messages (scheduled_for) WHERE status = 'SCHEDULED';

-- -----------------------------------------------------------------------------
-- tracking_events: eventos del embudo para el análisis del testing
-- visitor_id (cookie) mide el dashboard público antes del inicio de sesión.
-- El evento login_completed registra visitor_id y decision_maker_id juntos y
-- une lo anónimo con lo identificado. Datos variables (página, campo, tiempo,
-- UTM) van en properties.
-- Ejemplos de event_name: dashboard_viewed, cta_clicked, login_completed,
-- form_started, field_focused, field_completed, form_submitted,
-- confirmation_viewed, meeting_requested.
-- -----------------------------------------------------------------------------
CREATE TABLE tracking_events
(
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    visitor_id        uuid        NOT NULL,
    decision_maker_id uuid,
    form_session_id   uuid,
    event_name        text        NOT NULL,
    properties        jsonb       NOT NULL DEFAULT '{}'::jsonb,
    occurred_at       timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT fk_tracking_events_decision_maker
        FOREIGN KEY (decision_maker_id) REFERENCES decision_makers (id) ON DELETE SET NULL,
    CONSTRAINT fk_tracking_events_form_session
        FOREIGN KEY (form_session_id) REFERENCES form_sessions (id) ON DELETE SET NULL,
    CONSTRAINT ck_tracking_events_event_name CHECK (event_name ~ '^[a-z][a-z0-9_]*$'
)
    );

CREATE INDEX idx_tracking_events_name_occurred_at ON tracking_events (event_name, occurred_at);
CREATE INDEX idx_tracking_events_visitor_id ON tracking_events (visitor_id);

-- -----------------------------------------------------------------------------
-- Triggers de updated_at (solo en tablas cuyas filas se actualizan)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_simulations_updated_at
    BEFORE UPDATE
    ON simulations
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_decision_makers_updated_at
    BEFORE UPDATE
    ON decision_makers
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_form_sessions_updated_at
    BEFORE UPDATE
    ON form_sessions
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_challenges_updated_at
    BEFORE UPDATE
    ON challenges
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_meetings_updated_at
    BEFORE UPDATE
    ON meetings
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_email_messages_updated_at
    BEFORE UPDATE
    ON email_messages
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- Row Level Security
-- Supabase expone el esquema public por su API con la clave pública del
-- proyecto. Activar RLS sin políticas bloquea ese acceso. El backend se conecta
-- con el rol dueño de las tablas (postgres), que no queda alcanzado por RLS.
-- -----------------------------------------------------------------------------
ALTER TABLE simulations ENABLE ROW LEVEL SECURITY;
ALTER TABLE simulation_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE form_variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE decision_makers ENABLE ROW LEVEL SECURITY;
ALTER TABLE magic_link_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE form_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE challenges ENABLE ROW LEVEL SECURITY;
ALTER TABLE meetings ENABLE ROW LEVEL SECURITY;
ALTER TABLE email_messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE tracking_events ENABLE ROW LEVEL SECURITY;

-- -----------------------------------------------------------------------------
-- Datos iniciales: las dos variantes del formulario a testear (Pieza 2)
-- Los textos son una primera versión: UX/UI los ajusta con el testing.
-- Las preguntas guiadas siguen lo que surgió en la Etapa 1 ("planteando cada
-- parte", "explicaría el flujo de trabajo").
-- -----------------------------------------------------------------------------
INSERT INTO form_variants (code, name, field_schema)
VALUES ('free_text',
        'Texto libre',
        '{
          "fields": [
            {
              "key": "title",
              "type": "text",
              "label": "Ponele un título a tu desafío",
              "help": "Una frase corta, por ejemplo: Turnos online para una clínica.",
              "required": true,
              "max_length": 150
            },
            {
              "key": "description",
              "type": "textarea",
              "label": "Contanos qué problema querés resolver",
              "help": "Escribilo como se lo contarías a alguien que no conoce tu organización.",
              "required": true,
              "max_length": 4000
            }
          ]
        }'),
       ('guided',
        'Preguntas guiadas',
        '{
          "fields": [
            {
              "key": "title",
              "type": "text",
              "label": "Ponele un título a tu desafío",
              "help": "Una frase corta, por ejemplo: Turnos online para una clínica.",
              "required": true,
              "max_length": 150
            },
            {
              "key": "problem",
              "type": "textarea",
              "label": "¿Cuál es el problema?",
              "required": true,
              "max_length": 1500
            },
            {
              "key": "affected",
              "type": "text",
              "label": "¿A quién afecta?",
              "help": "Por ejemplo: clientes, alumnos, el equipo de ventas.",
              "required": true,
              "max_length": 300
            },
            {
              "key": "current_process",
              "type": "textarea",
              "label": "¿Cómo se resuelve hoy?",
              "help": "Contá el flujo de trabajo actual, aunque sea manual.",
              "required": false,
              "max_length": 1500
            },
            {
              "key": "expected_outcome",
              "type": "textarea",
              "label": "¿Qué resultado esperás al final?",
              "required": true,
              "max_length": 1000
            }
          ]
        }');
