# API.md — Contrato de API de UXFlow

**Este documento es el contrato entre el backend y el frontend.** Ningún equipo lo cambia por su cuenta.

- **Versión:** v1 — preliminar (Semana 2 de la simulación, 20 de octubre de 2026)
- **Base URL local:** `http://localhost:8080/api/v1`
- **Base URL staging:** `[por definir]`
- **Modelo de datos:** `schema_v1.sql` (11 tablas, PostgreSQL en Supabase)
- **Origen funcional:** documento de No Country *Simulación Laboral Abierta — UX Research* (Piezas 1 a 6)

> Este archivo es el **acuerdo**; el OpenAPI generado desde el código es la **implementación**. Si difieren, el código
> está mal o este documento no se actualizó: las dos cosas son un bug.

---

## Cómo cambiar este contrato

1. Abrir un PR que modifique **solo** este archivo.
2. Etiquetar a quien implementa el endpoint y a quien lo consume.
3. Esperar dos aprobaciones.
4. Recién entonces implementar.

**Cambios que rompen** (requieren aviso explícito): quitar o renombrar un campo, cambiar su tipo, volver obligatorio un
campo opcional, cambiar un código de estado o un valor de enum. **Cambios que no rompen:** agregar un campo opcional,
agregar un endpoint, agregar un valor nuevo a una lista de solo lectura.

---

## Índice

0. [Convenciones generales](#0-convenciones-generales)
1. [Normalización de datos](#1-normalización-de-datos)
2. [Formato de error](#2-formato-de-error)
3. [Autenticación y seguridad](#3-autenticación-y-seguridad)
4. [Dashboard público — Pieza 1](#4-dashboard-público--pieza-1)
5. [Acceso del decisor](#5-acceso-del-decisor)
6. [Perfil del decisor](#6-perfil-del-decisor)
7. [Formulario de carga — Piezas 2 y 4](#7-formulario-de-carga--piezas-2-y-4)
8. [Desafíos del decisor — Piezas 3, 5 y 6](#8-desafíos-del-decisor--piezas-3-5-y-6)
9. [Llamadas del decisor — Pieza 5](#9-llamadas-del-decisor--pieza-5)
10. [Panel de admin: acceso](#10-panel-de-admin-acceso)
11. [Panel de admin: desafíos](#11-panel-de-admin-desafíos)
12. [Panel de admin: llamadas](#12-panel-de-admin-llamadas)
13. [Panel de admin: simulaciones y métricas](#13-panel-de-admin-simulaciones-y-métricas)
14. [Webhook de Brevo](#14-webhook-de-brevo)
15. [Tracking (opcional)](#15-tracking-opcional)
16. [Procesos internos (sin endpoint)](#16-procesos-internos-sin-endpoint)
17. [Emails que dispara cada acción](#17-emails-que-dispara-cada-acción)
18. [Operación](#18-operación)
19. [Estado de implementación](#19-estado-de-implementación)

---

## 0. Convenciones generales

| Aspecto                  | Regla                                                                                               |
|--------------------------|-----------------------------------------------------------------------------------------------------|
| Formato                  | JSON. `Content-Type: application/json; charset=utf-8`                                               |
| Nombres                  | `camelCase` en JSON. Ver la excepción de `answers` en [Normalización](#1-normalización-de-datos)    |
| Fechas y horas           | ISO-8601 con zona. La API **responde siempre en UTC**: `2026-10-22T14:00:00Z`                       |
| Fechas sin hora          | `YYYY-MM-DD` (`2026-11-13`). Corresponden a las columnas `_on`                                      |
| Identificadores          | UUID como string                                                                                    |
| Enums                    | Strings en MAYÚSCULAS, iguales a los valores de la base (`SUBMITTED`, `TECH_LEAD`)                  |
| Nulos                    | `null` explícito. Nunca se omite el campo ni se usa `""`                                            |
| Listas simples           | `{ "count": 2, "items": [ ... ] }`                                                                  |
| Listas paginadas (admin) | `?page=0&size=20&sort=submittedAt,desc` → `{ "page", "size", "totalItems", "totalPages", "items" }` |
| Visitante anónimo        | Header `X-Visitor-Id: <uuid>`, generado por el frontend y guardado en `localStorage`                |
| Rate limit               | Header `X-RateLimit-Remaining` en las respuestas de endpoints limitados                             |

### Códigos de estado que usamos

`200` OK · `201` Creado · `202` Aceptado (trabajo asíncrono: envío de email) · `204` Sin contenido · `400` Entrada
inválida · `401` Sin autenticar · `403` Sin permiso · `404` No existe (o no es del usuario) · `409` Conflicto de
estado · `422` Regla de negocio violada · `429` Demasiadas peticiones · `500` Error del servidor · `503` Servicio no
disponible.

---

## 1. Normalización de datos

El backend normaliza **antes** de validar y guardar. El frontend puede enviar los datos tal como los escribió el
usuario.

| Dato                      | Regla                                                                                                                                    | Ejemplo                                     |
|---------------------------|------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------|
| Textos en general         | Se recortan espacios al inicio y al final. Un texto que queda vacío se trata como `null` (si el campo es obligatorio, es un error `400`) | `"  Ana  "` → `"Ana"`                       |
| Email                     | Recorte + minúsculas. Validación de formato. Máximo 254 caracteres                                                                       | `" Ana@Empresa.COM "` → `"ana@empresa.com"` |
| Teléfono                  | Recorte. Solo dígitos, espacios, `+`, `-` y paréntesis. Entre 1 y 30 caracteres                                                          | `"+54 9 299 404-1035"`                      |
| Zona horaria              | Nombre IANA válido (se verifica con la lista del runtime). Si no es válida → `400`                                                       | `"America/Mexico_City"`                     |
| Enums                     | Deben llegar exactamente en MAYÚSCULAS. Un valor distinto → `400`                                                                        | `"FOUNDER"` ✔ · `"founder"` ✘             |
| Fechas y horas de entrada | ISO-8601 **con** zona u offset. Sin zona → `400`                                                                                         | `"2026-10-22T09:00:00-06:00"`               |
| URL de videollamada       | Debe empezar con `https://`                                                                                                              | `"https://meet.google.com/abc-defg-hij"`    |
| Respuestas del formulario | Ver abajo                                                                                                                                | —                                           |

### Mapeo JSON ↔ base de datos

La API usa `camelCase`; la base, `snake_case`. La conversión es directa:

| JSON               | Columna                             |
|--------------------|-------------------------------------|
| `fullName`         | `decision_makers.full_name`         |
| `profileType`      | `decision_makers.profile_type`      |
| `organizationName` | `decision_makers.organization_name` |
| `formSessionId`    | `form_sessions.id`                  |
| `partialAnswers`   | `form_sessions.partial_answers`     |
| `lastFieldKey`     | `form_sessions.last_field_key`      |
| `submissionCount`  | `challenges.submission_count`       |
| `reviewFeedback`   | `challenges.review_feedback`        |
| `proposedSlots`    | `meetings.proposed_slots`           |
| `scheduledFor`     | `meetings.scheduled_for`            |

**Excepción: las claves dentro de `answers`, `partialAnswers` y `properties` no se convierten.** Son datos, no nombres
de la API: se usan exactamente como las define el `field_schema` de cada variante (`current_process`,
`expected_outcome`).

### Respuestas del formulario (`answers`)

- Es un objeto `{ "<key del campo>": "<texto>" }`.
- Solo se aceptan claves que existan en el `field_schema` de la variante del decisor. Una clave desconocida → `400`.
- Cada valor es texto, se recorta y se valida contra el `max_length` del campo.
- En el **autoguardado** no se exigen los campos obligatorios. En el **envío** sí.
- La validación es la de `validateAnswers(schema, answers, { partial })`.

---

## 2. Formato de error

RFC 9457 (*Problem Details*), igual en toda la API, con dos extensiones: `code` (para que el frontend decida qué mostrar
sin leer el texto) y `errors` (errores por campo).

```json
{
  "type": "https://uxflow.app/errors/validation",
  "title": "Datos de entrada inválidos",
  "status": 400,
  "code": "VALIDATION_ERROR",
  "detail": "Hay campos con errores.",
  "instance": "/api/v1/form/9b2e5c1a-3f4d-4e6a-9b7c-1d2e3f4a5b6c/submit",
  "traceId": "0af7651916cd43dd8448eb211c80319c",
  "errors": [
    {
      "field": "answers.expected_outcome",
      "message": "Este campo es obligatorio"
    },
    {
      "field": "answers.affected",
      "message": "Máximo 300 caracteres"
    }
  ]
}
```

- `errors` solo aparece en los `400` de validación. En el resto de los errores es `null`.
- `field` usa la ruta del dato en el body (`fullName`, `answers.affected`, `proposedSlots[1]`).
- `detail` es un texto para mostrar al usuario, en español.
- `traceId` sirve para encontrar el error en los logs.

### Catálogo de `code`

| `code`                | Status | Cuándo                                                                                              |
|-----------------------|--------|-----------------------------------------------------------------------------------------------------|
| `VALIDATION_ERROR`    | 400    | Datos con formato inválido o faltantes                                                              |
| `LINK_INVALID`        | 400    | Magic link inexistente, usado o vencido (siempre el mismo código para los tres casos)               |
| `UNAUTHENTICATED`     | 401    | Falta el token o venció                                                                             |
| `INVALID_CREDENTIALS` | 401    | Email o contraseña de admin incorrectos (mismo código para los dos casos)                           |
| `FORBIDDEN`           | 403    | Token válido pero de otro tipo (token de decisor en el panel de admin, o al revés)                  |
| `NOT_FOUND`           | 404    | No existe, o existe pero no pertenece al usuario                                                    |
| `ALREADY_SUBMITTED`   | 409    | La sesión del formulario ya se envió                                                                |
| `INVALID_STATUS`      | 409    | La acción no corresponde al estado actual (por ejemplo, aprobar un desafío que no está en revisión) |
| `DUPLICATE_REQUEST`   | 409    | Ya existe una solicitud de llamada abierta para el mismo motivo                                     |
| `PROFILE_INCOMPLETE`  | 422    | Faltan nombre, perfil, organización o consentimiento                                                |
| `SLOT_IN_PAST`        | 422    | Una fecha propuesta o agendada no es futura                                                         |
| `RATE_LIMITED`        | 429    | Se superó el límite de pedidos                                                                      |
| `INTERNAL_ERROR`      | 500    | Error no controlado. `detail` genérico, sin datos internos                                          |

---

## 3. Autenticación y seguridad

### Dos tipos de usuario, dos tipos de token

|            | Decisor                                                                              | Admin                               |
|------------|--------------------------------------------------------------------------------------|-------------------------------------|
| Cómo entra | Magic link o Google                                                                  | Email y contraseña                  |
| Token      | JWT `Authorization: Bearer <token>`                                                  | JWT `Authorization: Bearer <token>` |
| `aud`      | `uxflow-app`                                                                         | `uxflow-admin`                      |
| `role`     | `DECISION_MAKER`                                                                     | `ADMIN`                             |
| Duración   | 1 hora                                                                               | 8 horas                             |
| Rutas      | `/public/*` (algunas) y las del decisor (`/me`, `/form`, `/challenges`, `/meetings`) | `/admin/*`                          |

Payload del JWT (sin datos personales: el payload no está cifrado):

```json
{
  "sub": "5b1e8c2a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
  "role": "DECISION_MAKER",
  "aud": "uxflow-app",
  "iss": "uxflow-api",
  "iat": 1792450560,
  "exp": 1792454160
}
```

- Un token con `aud` distinto al de la ruta → `403 FORBIDDEN`.
- No hay endpoint de logout: el JWT no se guarda en el servidor, el frontend lo descarta. Las sesiones revocables quedan
  para una versión posterior.
- En los endpoints del admin, el middleware verifica además que el admin siga existiendo.

### Reglas de propiedad

- **El dueño nunca viaja en la ruta ni en el body.** El backend toma `decisionMakerId` del `sub` del token.
- Un recurso de otro decisor responde `404`, no `403`: no se revela que existe.

### Rate limits

| Endpoint                              | Límite                                           |
|---------------------------------------|--------------------------------------------------|
| `POST /public/auth/magic-link`        | 3 por email cada 15 minutos · 10 por IP por hora |
| `POST /public/auth/magic-link/verify` | 10 por IP cada 15 minutos                        |
| `POST /admin/auth/login`              | 5 por email cada 15 minutos · 20 por IP por hora |
| `POST /public/events`                 | 120 por `X-Visitor-Id` por minuto                |

### CORS y página de login

- CORS habilitado solo para el dominio del frontend.
- La página `/login?token=...` del frontend envía `Referrer-Policy: no-referrer`, para que el token no se filtre a otros
  sitios.

---

## 4. Dashboard público — Pieza 1

Tablas: `simulations`, `simulation_projects`. Datos sincronizados desde la web pública de No Country
(ver [Procesos internos](#16-procesos-internos-sin-endpoint)).

### `GET /public/dashboard`

Datos de la simulación actual y sus proyectos. Público, sin autenticación, con caché de 5 minutos.

**Response `200`**

```json
{
  "simulation": {
    "id": "7c0e2a51-9d1b-4f3e-8a6c-2b4d5e6f7a8b",
    "name": "Simulación Laboral – Octubre 2026",
    "startsOn": "2026-10-12",
    "endsOn": "2026-11-16",
    "demoDayOn": "2026-11-13",
    "isActive": true,
    "currentWeek": 2,
    "totalWeeks": 5,
    "registrantCount": 243,
    "countryCount": 17,
    "projectCount": 7,
    "teamCount": 34,
    "participantCount": 214,
    "syncedAt": "2026-10-20T06:00:00Z"
  },
  "projects": [
    {
      "id": "3a9f1c2d-4b5e-4f6a-8b7c-9d0e1f2a3b4c",
      "name": "NautiFlow",
      "category": "Web App Development",
      "teamCount": 7,
      "participantCount": 52
    },
    {
      "id": "4b0a2d3e-5c6f-4a7b-9c8d-0e1f2a3b4c5d",
      "name": "UXFlow",
      "category": "Web App Development",
      "teamCount": 4,
      "participantCount": 35
    }
  ]
}
```

- `isActive`, `currentWeek` y `totalWeeks` se calculan con `startsOn`, `endsOn` y la fecha actual. No se guardan.
- `projectCount`, `teamCount` y `participantCount` de la simulación son sumas de `projects`.
- `projects` viene ordenado por `teamCount` descendente.
- Sin simulación cargada → `200` con `"simulation": null` y `"projects": []`. No es un error: el frontend muestra un
  estado vacío.

---

## 5. Acceso del decisor

Tablas: `decision_makers`, `magic_link_tokens`, `email_messages` (`MAGIC_LINK`).

### `POST /public/auth/magic-link`

Crea al decisor si su email no existe y le envía un magic link. Header opcional `X-Visitor-Id` (para el evento
`login_requested`).

**Request**

```json
{
  "email": "ana@empresa.com"
}
```

**Response `202`**

```json
{
  "message": "Si el email es correcto, te va a llegar un link de acceso en unos segundos.",
  "expiresInSeconds": 900
}
```

- La respuesta es **idéntica** exista o no el email, y aunque se haya superado el límite de pedidos. No se revela qué
  emails están registrados.
- El link vence a los 15 minutos y sirve una sola vez.
- El email se registra en `decision_makers` aunque el decisor nunca use el link (`email_verified_at` queda `null`).

**Errores:** `400 VALIDATION_ERROR` email inválido · `429 RATE_LIMITED` por IP.

### `GET /public/auth/magic-link?token=...`

Datos para la página de confirmación. **Solo lee: no consume el token.** Así, si un filtro de seguridad del correo abre
el link, el token sigue sin usar.

**Response `200`**

```json
{
  "status": "VALID",
  "maskedEmail": "a*a@empresa.com",
  "expiresAt": "2026-10-20T19:45:00Z"
}
```

**Errores:** `400 LINK_INVALID`.

### `POST /public/auth/magic-link/verify`

Canjea el token por un access token. Lo llama el botón "Confirmar ingreso" de la página. Header opcional `X-Visitor-Id`
(para el evento `login_completed`).

**Request**

```json
{
  "token": "q8Zx3vK1pL9mN2rT7wY4bC6dF0gH5jSaB1cD2eF3gH4"
}
```

**Response `200`**

```json
{
  "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "tokenType": "Bearer",
  "expiresAt": "2026-10-20T20:30:00Z",
  "decisionMaker": {
    "id": "5b1e8c2a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
    "email": "ana@empresa.com",
    "fullName": null,
    "profileCompleted": false
  }
}
```

- El primer canje completa `email_verified_at`.
- El frontend decide a dónde navegar: si `profileCompleted` es `false`, a completar el perfil; si es `true`, a la
  pantalla de elección (formulario o llamada).

**Errores:** `400 LINK_INVALID` · `429 RATE_LIMITED`.

### `POST /public/auth/google`

Inicio de sesión con Google. El frontend obtiene el `idToken` con Google Identity Services y el backend lo verifica con
Google.

**Request**

```json
{
  "idToken": "eyJhbGciOiJSUzI1NiIsImtpZCI6..."
}
```

**Response `200`**: igual que `/magic-link/verify`. Si el decisor es nuevo, `fullName` viene precargado con el nombre de
su cuenta de Google.

- Busca al decisor por `google_sub`. Si no existe, por email. Si tampoco existe, lo crea.
- Completa `email_verified_at` y `google_sub`.

**Errores:** `400 VALIDATION_ERROR` token de Google inválido o con email no verificado.

---

## 6. Perfil del decisor

Tabla: `decision_makers`. Requiere token de decisor.

### `GET /me` 🔒

**Response `200`**

```json
{
  "id": "5b1e8c2a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
  "email": "ana@empresa.com",
  "fullName": "Ana Pérez",
  "profileType": "FOUNDER",
  "organizationName": "Empresa SA",
  "phone": null,
  "timezone": "America/Argentina/Buenos_Aires",
  "consentAccepted": true,
  "profileCompleted": true,
  "hasGoogle": false,
  "createdAt": "2026-10-20T19:30:00Z"
}
```

`profileCompleted` es `true` cuando están completos `fullName`, `profileType`, `organizationName` y el consentimiento.

### `PATCH /me` 🔒

Completa o modifica el perfil. Solo se actualizan los campos enviados.

**Request**

```json
{
  "fullName": "Ana Pérez",
  "profileType": "FOUNDER",
  "organizationName": "Empresa SA",
  "phone": null,
  "timezone": "America/Argentina/Buenos_Aires",
  "consentAccepted": true
}
```

| Campo              | Tipo           | Reglas                                                                                         |
|--------------------|----------------|------------------------------------------------------------------------------------------------|
| `fullName`         | string         | 1 a 120 caracteres                                                                             |
| `profileType`      | enum           | `TEACHER` · `TECH_LEAD` · `FOUNDER` · `SENIOR_PROFESSIONAL` · `OTHER`                          |
| `organizationName` | string         | 1 a 150 caracteres                                                                             |
| `phone`            | string \| null | Opcional. 1 a 30 caracteres                                                                    |
| `timezone`         | string         | Zona IANA. El frontend la envía siempre con `Intl.DateTimeFormat().resolvedOptions().timeZone` |
| `consentAccepted`  | boolean        | Solo se acepta `true`. Guarda `consent_accepted_at` la primera vez                             |

**Response `200`**: igual que `GET /me`.

**Errores:** `400 VALIDATION_ERROR` · `401 UNAUTHENTICATED`.

---

## 7. Formulario de carga — Piezas 2 y 4

Tablas: `form_variants`, `form_sessions`. Requiere token de decisor **y perfil completo**.

### `GET /form` 🔒

Devuelve el formulario del decisor con su borrador. El backend decide la sesión y la variante:

1. Si el decisor tiene una sesión **sin enviar** (`completed_at IS NULL`), la devuelve con su borrador.
2. Si no, crea una sesión nueva:
    - con la **variante que usó antes**, si sigue activa;
    - si no usó ninguna, con una **al azar** entre las activas.

**Response `200`**

```json
{
  "formSessionId": "9b2e5c1a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
  "variant": {
    "code": "guided",
    "name": "Preguntas guiadas"
  },
  "fields": [
    {
      "key": "title",
      "type": "text",
      "label": "Ponele un título a tu desafío",
      "help": "Una frase corta, por ejemplo: Turnos online para una clínica.",
      "required": true,
      "maxLength": 150
    },
    {
      "key": "problem",
      "type": "textarea",
      "label": "¿Cuál es el problema?",
      "help": null,
      "required": true,
      "maxLength": 1500
    },
    {
      "key": "affected",
      "type": "text",
      "label": "¿A quién afecta?",
      "help": "Por ejemplo: clientes, alumnos, el equipo de ventas.",
      "required": true,
      "maxLength": 300
    },
    {
      "key": "current_process",
      "type": "textarea",
      "label": "¿Cómo se resuelve hoy?",
      "help": "Contá el flujo de trabajo actual, aunque sea manual.",
      "required": false,
      "maxLength": 1500
    },
    {
      "key": "expected_outcome",
      "type": "textarea",
      "label": "¿Qué resultado esperás al final?",
      "help": null,
      "required": true,
      "maxLength": 1000
    }
  ],
  "partialAnswers": {
    "title": "Turnos de la clínica"
  },
  "lastFieldKey": "title",
  "createdAt": "2026-10-20T19:35:00Z"
}
```

- `fields` sale del `field_schema` de la variante. Las propiedades de cada campo pasan a `camelCase` (`max_length` →
  `maxLength`) y `help` ausente se devuelve como `null`. La `key` de cada campo no cambia.
- El frontend dibuja un campo por elemento, en ese orden. El mismo componente sirve para las dos variantes.

**Errores:** `401 UNAUTHENTICATED` · `422 PROFILE_INCOMPLETE`.

### `PATCH /form/{formSessionId}` 🔒

Autoguardado. Se llama cuando el decisor sale de un campo o un segundo después de que deja de escribir. Envía **solo lo
que cambió**.

**Request**

```json
{
  "answers": {
    "affected": "Recepcionistas y pacientes"
  },
  "lastFieldKey": "affected"
}
```

- El backend combina `answers` con el borrador existente (`partial_answers || answers`), actualiza `last_field_key` y
  `last_activity_at`.
- Valida en modo parcial: claves conocidas y largo máximo, sin exigir obligatorios.
- `lastFieldKey` debe ser una `key` de la variante.

**Response `200`**

```json
{
  "formSessionId": "9b2e5c1a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
  "savedAt": "2026-10-20T19:41:12Z"
}
```

**Errores:** `400 VALIDATION_ERROR` · `404 NOT_FOUND` · `409 ALREADY_SUBMITTED`.

### `POST /form/{formSessionId}/submit` 🔒

Envía el desafío. El frontend manda **todas** las respuestas, no solo la última.

**Request**

```json
{
  "answers": {
    "title": "Turnos de la clínica",
    "problem": "Los turnos se gestionan por WhatsApp y se pierden",
    "affected": "Recepcionistas y pacientes",
    "current_process": "La recepcionista anota en una planilla",
    "expected_outcome": "Que el paciente reserve solo"
  }
}
```

En una sola transacción, el backend:

1. Valida `answers` completo, con los obligatorios.
2. Cierra la sesión (`completed_at`) y guarda la versión final en `partial_answers`.
3. Crea el desafío: `source = FORM`, `status = SUBMITTED`, `title = answers.title`.
4. Cancela los emails de recuperación pendientes de esa sesión.
5. Programa el email `SUBMISSION_CONFIRMATION`.

**Response `201`** (cabecera `Location: /api/v1/challenges/{id}`)

```json
{
  "challengeId": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
  "status": "SUBMITTED",
  "submittedAt": "2026-10-20T19:45:00Z",
  "estimatedResponseHours": 48
}
```

`estimatedResponseHours` alimenta la pantalla posterior al envío ("Revisamos tu propuesta dentro de las próximas 48
horas").

**Errores:** `400 VALIDATION_ERROR` (con `errors` por campo) · `404 NOT_FOUND` · `409 ALREADY_SUBMITTED` (incluye el
`challengeId` existente en `detail`) · `422 PROFILE_INCOMPLETE`.

---

## 8. Desafíos del decisor — Piezas 3, 5 y 6

Tabla: `challenges`. Requiere token de decisor.

### `GET /challenges` 🔒

Listado del decisor: título, fecha de envío y estado. Del más reciente al más antiguo.

**Response `200`**

```json
{
  "count": 2,
  "items": [
    {
      "id": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
      "title": "Turnos de la clínica",
      "source": "FORM",
      "status": "CONTEXT_REQUESTED",
      "submittedAt": "2026-10-20T19:45:00Z",
      "submissionCount": 1,
      "reviewFeedback": "Falta saber cuántos turnos manejan por día.",
      "simulation": null,
      "availableActions": [
        "RESUBMIT",
        "REQUEST_MEETING"
      ]
    },
    {
      "id": "8a2b3c4d-5e6f-4a7b-9c8d-0e1f2a3b4c5d",
      "title": "Plataforma de cursos",
      "source": "MEETING",
      "status": "APPROVED",
      "submittedAt": "2026-10-18T15:00:00Z",
      "submissionCount": 1,
      "reviewFeedback": null,
      "simulation": {
        "id": "1d2e3f4a-5b6c-4d7e-8f9a-0b1c2d3e4f5a",
        "name": "Simulación Laboral – Diciembre 2026",
        "startsOn": "2026-12-07"
      },
      "availableActions": []
    }
  ]
}
```

- `reviewFeedback` solo viene con valor en `REJECTED` y `CONTEXT_REQUESTED`.
- `availableActions` le indica al frontend qué botones mostrar: `RESUBMIT` (modificar y reenviar) y `REQUEST_MEETING`
  (pedir una llamada). Ambas solo en `REJECTED` y `CONTEXT_REQUESTED`.
- `quality_score` e `initial_quality_score` **no se exponen** al decisor.

| `status`            | Texto sugerido en el listado |
|---------------------|------------------------------|
| `SUBMITTED`         | Pendiente                    |
| `IN_REVIEW`         | En revisión                  |
| `CONTEXT_REQUESTED` | Necesitamos más información  |
| `APPROVED`          | Aprobado                     |
| `REJECTED`          | No aprobado                  |

### `GET /challenges/{challengeId}` 🔒

Detalle del desafío, con las respuestas y los campos para poder editarlo.

**Response `200`**

```json
{
  "id": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
  "title": "Turnos de la clínica",
  "source": "FORM",
  "status": "CONTEXT_REQUESTED",
  "answers": {
    "title": "Turnos de la clínica",
    "problem": "Los turnos se gestionan por WhatsApp y se pierden",
    "affected": "Recepcionistas y pacientes",
    "current_process": "La recepcionista anota en una planilla",
    "expected_outcome": "Que el paciente reserve solo"
  },
  "fields": [
    {
      "key": "title",
      "type": "text",
      "label": "Ponele un título a tu desafío",
      "help": "Una frase corta, por ejemplo: Turnos online para una clínica.",
      "required": true,
      "maxLength": 150
    }
  ],
  "submittedAt": "2026-10-20T19:45:00Z",
  "submissionCount": 1,
  "reviewFeedback": "Falta saber cuántos turnos manejan por día.",
  "simulation": null,
  "availableActions": [
    "RESUBMIT",
    "REQUEST_MEETING"
  ],
  "meetings": [
    {
      "id": "3c9d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
      "purpose": "REVIEW_FOLLOW_UP",
      "status": "REQUESTED",
      "scheduledFor": null
    }
  ]
}
```

- `fields` es el `field_schema` de la variante con la que se cargó (en el ejemplo se muestra recortado). Los desafíos
  con `source = MEETING` usan los campos de `free_text`.

**Errores:** `404 NOT_FOUND`.

### `POST /challenges/{challengeId}/resubmit` 🔒

Modifica y reenvía un desafío rechazado o con contexto pedido.

**Request**

```json
{
  "answers": {
    "title": "Turnos de la clínica",
    "problem": "Los turnos se gestionan por WhatsApp y se pierden. Manejamos unos 200 por día.",
    "affected": "Recepcionistas y pacientes",
    "current_process": "La recepcionista anota en una planilla",
    "expected_outcome": "Que el paciente reserve solo"
  }
}
```

El backend valida igual que en el envío y actualiza: `answers`, `title`, `status = SUBMITTED`, `submission_count + 1`,
`submitted_at = now()`, `reviewed_at = null`. `review_feedback` e `initial_quality_score` se conservan.

**Response `200`**

```json
{
  "challengeId": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
  "status": "SUBMITTED",
  "submissionCount": 2,
  "submittedAt": "2026-10-22T13:10:00Z",
  "estimatedResponseHours": 48
}
```

**Errores:** `400 VALIDATION_ERROR` · `404 NOT_FOUND` · `409 INVALID_STATUS` (si no está en `REJECTED` ni
`CONTEXT_REQUESTED`).

---

## 9. Llamadas del decisor — Pieza 5

Tabla: `meetings`. Requiere token de decisor **y perfil completo**.

### `POST /meetings` 🔒

Pide una llamada y propone entre 1 y 3 horarios.

**Request**

```json
{
  "purpose": "DESCRIBE_CHALLENGE",
  "challengeId": null,
  "proposedSlots": [
    "2026-10-22T09:00:00-06:00",
    "2026-10-23T16:00:00-06:00"
  ],
  "availabilityNotes": "Mejor por la mañana"
}
```

| Campo               | Reglas                                                                                                                          |
|---------------------|---------------------------------------------------------------------------------------------------------------------------------|
| `purpose`           | `DESCRIBE_CHALLENGE` · `LEARN_MORE` · `REVIEW_FOLLOW_UP`                                                                        |
| `challengeId`       | Obligatorio solo para `REVIEW_FOLLOW_UP`: un desafío propio en `REJECTED` o `CONTEXT_REQUESTED`. Para los otros motivos, `null` |
| `proposedSlots`     | 1 a 3 fechas y horas futuras (al menos 2 horas desde ahora), sin repetir                                                        |
| `availabilityNotes` | Opcional. Hasta 500 caracteres                                                                                                  |

El backend crea la llamada en `REQUESTED` y avisa a los admins por email.

**Response `201`**

```json
{
  "id": "3c9d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
  "purpose": "DESCRIBE_CHALLENGE",
  "status": "REQUESTED",
  "challengeId": null,
  "proposedSlots": [
    "2026-10-22T15:00:00Z",
    "2026-10-23T22:00:00Z"
  ],
  "availabilityNotes": "Mejor por la mañana",
  "scheduledFor": null,
  "meetingUrl": null,
  "estimatedResponseHours": 48,
  "createdAt": "2026-10-20T19:50:00Z"
}
```

Las fechas se reciben con el offset del decisor y se devuelven en UTC. El frontend las muestra en la zona del decisor.

**Errores:** `400 VALIDATION_ERROR` · `404 NOT_FOUND` (desafío ajeno) · `409 DUPLICATE_REQUEST` (ya tiene una llamada
`REQUESTED` o `SCHEDULED` con el mismo motivo y el mismo desafío) · `409 INVALID_STATUS` (desafío en un estado que no
admite seguimiento) · `422 PROFILE_INCOMPLETE` · `422 SLOT_IN_PAST`.

### `GET /meetings` 🔒

Llamadas del decisor, de la más reciente a la más antigua.

**Response `200`**

```json
{
  "count": 1,
  "items": [
    {
      "id": "3c9d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
      "purpose": "DESCRIBE_CHALLENGE",
      "status": "SCHEDULED",
      "challengeId": null,
      "proposedSlots": [
        "2026-10-22T15:00:00Z",
        "2026-10-23T22:00:00Z"
      ],
      "availabilityNotes": "Mejor por la mañana",
      "scheduledFor": "2026-10-22T15:00:00Z",
      "meetingUrl": "https://meet.google.com/abc-defg-hij",
      "availableActions": [
        "RESCHEDULE",
        "CANCEL"
      ],
      "createdAt": "2026-10-20T19:50:00Z"
    }
  ]
}
```

`notes` (lo que escribe el admin) no se expone al decisor.

### `POST /meetings/{meetingId}/reschedule` 🔒

"No puedo en este horario". El decisor propone nuevas opciones y la llamada vuelve a `REQUESTED`.

**Request**

```json
{
  "proposedSlots": [
    "2026-10-26T10:00:00-06:00"
  ],
  "availabilityNotes": null
}
```

Se limpian `scheduledFor` y `meetingUrl`, y se avisa a los admins.

**Response `200`**: igual que un elemento de `GET /meetings`.

**Errores:** `400 VALIDATION_ERROR` · `404 NOT_FOUND` · `409 INVALID_STATUS` (solo desde `REQUESTED` o `SCHEDULED`) ·
`422 SLOT_IN_PAST`.

### `POST /meetings/{meetingId}/cancel` 🔒

El decisor cancela la llamada. Pasa a `CANCELLED` y se avisa a los admins.

**Response `204`**

**Errores:** `404 NOT_FOUND` · `409 INVALID_STATUS` (solo desde `REQUESTED` o `SCHEDULED`).

---

## 10. Panel de admin: acceso

Tabla: `admin_users`. Los admins se crean por script, no hay registro público.

### `POST /admin/auth/login`

**Request**

```json
{
  "email": "rev@uxflow.dev",
  "password": "••••••••"
}
```

**Response `200`**

```json
{
  "accessToken": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9...",
  "tokenType": "Bearer",
  "expiresAt": "2026-10-21T03:00:00Z",
  "admin": {
    "id": "9a7d6c5b-4e3f-4a2b-8c1d-0e9f8a7b6c5d",
    "email": "rev@uxflow.dev",
    "fullName": "Revisor"
  }
}
```

**Errores:** `401 INVALID_CREDENTIALS` (mismo código si el email no existe o la contraseña es incorrecta) ·
`429 RATE_LIMITED`.

### `GET /admin/auth/me` 🔒 ADMIN

**Response `200`**: el objeto `admin` de la respuesta anterior.

---

## 11. Panel de admin: desafíos

Tabla: `challenges` (más `decision_makers`, `form_sessions`, `form_variants` y `meetings` para el detalle). Requiere
token de admin.

### `GET /admin/challenges` 🔒 ADMIN

Listado paginado. Por defecto muestra la cola de revisión: `SUBMITTED` e `IN_REVIEW`, del envío más antiguo al más
nuevo.

**Query:** `status` (uno o varios separados por coma) · `source` (`FORM` · `MEETING`) · `page` · `size` · `sort`
(`submittedAt,asc` por defecto).

**Response `200`**

```json
{
  "page": 0,
  "size": 20,
  "totalItems": 1,
  "totalPages": 1,
  "items": [
    {
      "id": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
      "title": "Turnos de la clínica",
      "source": "FORM",
      "variantCode": "guided",
      "status": "SUBMITTED",
      "submittedAt": "2026-10-20T19:45:00Z",
      "submissionCount": 1,
      "qualityScore": null,
      "decisionMaker": {
        "id": "5b1e8c2a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
        "fullName": "Ana Pérez",
        "profileType": "FOUNDER",
        "organizationName": "Empresa SA"
      }
    }
  ]
}
```

`variantCode` es `null` en los desafíos con `source = MEETING`.

### `GET /admin/challenges/{challengeId}` 🔒 ADMIN

**Response `200`**

```json
{
  "id": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
  "title": "Turnos de la clínica",
  "source": "FORM",
  "variantCode": "guided",
  "status": "IN_REVIEW",
  "answers": {
    "title": "Turnos de la clínica",
    "problem": "Los turnos se gestionan por WhatsApp y se pierden",
    "affected": "Recepcionistas y pacientes",
    "current_process": "La recepcionista anota en una planilla",
    "expected_outcome": "Que el paciente reserve solo"
  },
  "fields": [
    {
      "key": "title",
      "type": "text",
      "label": "Ponele un título a tu desafío",
      "help": "Una frase corta, por ejemplo: Turnos online para una clínica.",
      "required": true,
      "maxLength": 150
    }
  ],
  "qualityScore": null,
  "initialQualityScore": null,
  "reviewFeedback": null,
  "submissionCount": 1,
  "submittedAt": "2026-10-20T19:45:00Z",
  "reviewedAt": null,
  "simulation": null,
  "decisionMaker": {
    "id": "5b1e8c2a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
    "email": "ana@empresa.com",
    "fullName": "Ana Pérez",
    "profileType": "FOUNDER",
    "organizationName": "Empresa SA",
    "phone": null,
    "timezone": "America/Argentina/Buenos_Aires"
  },
  "meetings": [],
  "createdAt": "2026-10-20T19:45:00Z"
}
```

En el ejemplo, `fields` se muestra recortado: trae todos los campos de la variante.

### `POST /admin/challenges/{challengeId}/start-review` 🔒 ADMIN

Pasa de `SUBMITTED` a `IN_REVIEW` y programa el email `REVIEW_STARTED`. Sin body.

**Response `200`**

```json
{
  "challengeId": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
  "status": "IN_REVIEW"
}
```

**Errores:** `404 NOT_FOUND` · `409 INVALID_STATUS`.

### `POST /admin/challenges/{challengeId}/review` 🔒 ADMIN

Decisión de la revisión. Solo desde `IN_REVIEW`.

**Request**

```json
{
  "decision": "CONTEXT_REQUESTED",
  "qualityScore": 2,
  "reviewFeedback": "Falta saber cuántos turnos manejan por día."
}
```

| Campo            | Reglas                                                                                    |
|------------------|-------------------------------------------------------------------------------------------|
| `decision`       | `APPROVED` · `REJECTED` · `CONTEXT_REQUESTED`                                             |
| `qualityScore`   | Obligatorio. Entero de 1 a 5, según la rúbrica (`GET /admin/quality-rubric`)              |
| `reviewFeedback` | Obligatorio en `REJECTED` y `CONTEXT_REQUESTED`. Hasta 2.000 caracteres. Lo ve el decisor |

El backend guarda `status`, `quality_score`, `review_feedback` y `reviewed_at`, completa `initial_quality_score` solo si
está vacío, y programa el email que corresponde: `APPROVAL`, `REJECTION` o `CONTEXT_REQUEST`.

**Response `200`**

```json
{
  "challengeId": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
  "status": "CONTEXT_REQUESTED",
  "qualityScore": 2,
  "initialQualityScore": 2,
  "reviewedAt": "2026-10-21T15:00:00Z"
}
```

**Errores:** `400 VALIDATION_ERROR` · `404 NOT_FOUND` · `409 INVALID_STATUS`.

### `POST /admin/challenges/{challengeId}/assign-simulation` 🔒 ADMIN

Asigna la simulación en la que va a participar un desafío aprobado y programa el email `SIMULATION_ASSIGNED`.

**Request**

```json
{
  "simulationId": "1d2e3f4a-5b6c-4d7e-8f9a-0b1c2d3e4f5a"
}
```

**Response `200`**

```json
{
  "challengeId": "7f1a2b3c-4d5e-4f6a-8b7c-9d0e1f2a3b4c",
  "status": "APPROVED",
  "simulation": {
    "id": "1d2e3f4a-5b6c-4d7e-8f9a-0b1c2d3e4f5a",
    "name": "Simulación Laboral – Diciembre 2026",
    "startsOn": "2026-12-07"
  }
}
```

**Errores:** `404 NOT_FOUND` (desafío o simulación) · `409 INVALID_STATUS` (si no está `APPROVED`).

### `GET /admin/quality-rubric` 🔒 ADMIN

Criterios de calificación que el panel muestra junto al selector de puntaje. Es una constante del backend.

**Response `200`**

```json
{
  "items": [
    {
      "score": 1,
      "description": "No se entiende cuál es el problema"
    },
    {
      "score": 2,
      "description": "Se entiende el problema, pero falta a quién afecta o qué resultado espera"
    },
    {
      "score": 3,
      "description": "Problema, afectados y resultado claros, pero falta contexto para empezar a trabajar"
    },
    {
      "score": 4,
      "description": "Un equipo podría empezar a trabajar con alguna pregunta menor"
    },
    {
      "score": 5,
      "description": "Un equipo podría empezar a trabajar sin hacer preguntas"
    }
  ]
}
```

---

## 12. Panel de admin: llamadas

Tabla: `meetings`. Requiere token de admin.

### `GET /admin/meetings` 🔒 ADMIN

Listado paginado. Por defecto, las solicitudes pendientes (`REQUESTED`), de la más antigua a la más nueva.

**Query:** `status` (uno o varios) · `purpose` · `page` · `size` · `sort` (`createdAt,asc` por defecto).

**Response `200`**

```json
{
  "page": 0,
  "size": 20,
  "totalItems": 1,
  "totalPages": 1,
  "items": [
    {
      "id": "3c9d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
      "purpose": "DESCRIBE_CHALLENGE",
      "status": "REQUESTED",
      "challengeId": null,
      "proposedSlots": [
        "2026-10-22T15:00:00Z",
        "2026-10-23T22:00:00Z"
      ],
      "availabilityNotes": "Mejor por la mañana",
      "scheduledFor": null,
      "meetingUrl": null,
      "decisionMaker": {
        "id": "6c2f9d3b-4a5e-4f7a-8b9c-0d1e2f3a4b5c",
        "fullName": "Juan Gómez",
        "organizationName": "Escuela 12",
        "email": "juan@escuela.edu",
        "timezone": "America/Mexico_City"
      },
      "createdAt": "2026-10-20T19:50:00Z"
    }
  ]
}
```

### `GET /admin/meetings/{meetingId}` 🔒 ADMIN

**Response `200`**: un elemento del listado, más `notes` y `updatedAt`.

### `POST /admin/meetings/{meetingId}/schedule` 🔒 ADMIN

Confirma la llamada. Solo desde `REQUESTED`. Lo habitual es elegir una de las `proposedSlots`, pero se acepta cualquier
fecha futura.

**Request**

```json
{
  "scheduledFor": "2026-10-22T15:00:00Z",
  "meetingUrl": "https://meet.google.com/abc-defg-hij"
}
```

Pasa a `SCHEDULED`, programa el email `MEETING_SCHEDULED` para el decisor (con la hora en su zona) y avisa a los admins.

**Response `200`**: el detalle de la llamada.

**Errores:** `400 VALIDATION_ERROR` (URL que no empieza con `https://`) · `404 NOT_FOUND` · `409 INVALID_STATUS` ·
`422 SLOT_IN_PAST`.

### `POST /admin/meetings/{meetingId}/complete` 🔒 ADMIN

Marca la llamada como realizada. Solo desde `SCHEDULED`.

**Request**

```json
{
  "notes": "Plataforma de cursos para 300 alumnos. Prefiere avanzar en enero."
}
```

**Response `200`**: el detalle de la llamada, con `status = COMPLETED`.

**Errores:** `404 NOT_FOUND` · `409 INVALID_STATUS`.

### `POST /admin/meetings/{meetingId}/cancel` 🔒 ADMIN

Cancela la llamada. Desde `REQUESTED` o `SCHEDULED`. `reason` es opcional y se agrega a `notes`.

**Request**

```json
{
  "reason": "El decisor no respondió."
}
```

**Response `204`**

**Errores:** `404 NOT_FOUND` · `409 INVALID_STATUS`.

### `POST /admin/meetings/{meetingId}/challenge` 🔒 ADMIN

Carga el desafío que el decisor contó en la llamada. Solo para `purpose = DESCRIBE_CHALLENGE`, desde `SCHEDULED` o
`COMPLETED`, y si la llamada todavía no tiene desafío. El decisor se toma de la llamada, no viaja en el body.

**Request**

```json
{
  "answers": {
    "title": "Plataforma de cursos",
    "description": "Necesitan una plataforma para 300 alumnos con seguimiento de entregas."
  },
  "notes": "Prefiere avanzar en enero."
}
```

- `answers` usa los campos de la variante `free_text` (`title` y `description`), obligatorios los dos.
- En una sola transacción: crea el desafío (`source = MEETING`, `status = SUBMITTED`), lo vincula a la llamada, la marca
  `COMPLETED` y guarda `notes`.
- Programa el email `SUBMISSION_CONFIRMATION`: el decisor ve el desafío en su listado y puede revisar cómo quedó.
- Si el decisor no tiene el perfil completo → `422 PROFILE_INCOMPLETE`. Se resuelve completando el perfil desde la
  llamada.

**Response `201`**

```json
{
  "challengeId": "8a2b3c4d-5e6f-4a7b-9c8d-0e1f2a3b4c5d",
  "meetingId": "3c9d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f",
  "status": "SUBMITTED"
}
```

**Errores:** `400 VALIDATION_ERROR` · `404 NOT_FOUND` · `409 INVALID_STATUS` (motivo distinto, estado no válido o
desafío ya cargado) · `422 PROFILE_INCOMPLETE`.

---

## 13. Panel de admin: simulaciones y métricas

### `GET /admin/simulations` 🔒 ADMIN

Simulaciones disponibles para asignar desafíos aprobados, de la más próxima a la más lejana.

**Response `200`**

```json
{
  "count": 2,
  "items": [
    {
      "id": "7c0e2a51-9d1b-4f3e-8a6c-2b4d5e6f7a8b",
      "name": "Simulación Laboral – Octubre 2026",
      "startsOn": "2026-10-12",
      "endsOn": "2026-11-16",
      "demoDayOn": "2026-11-13",
      "assignedChallengeCount": 0
    },
    {
      "id": "1d2e3f4a-5b6c-4d7e-8f9a-0b1c2d3e4f5a",
      "name": "Simulación Laboral – Diciembre 2026",
      "startsOn": "2026-12-07",
      "endsOn": "2027-01-15",
      "demoDayOn": null,
      "assignedChallengeCount": 3
    }
  ]
}
```

### `POST /admin/simulations` 🔒 ADMIN

Carga una simulación futura para poder asignarle desafíos.

**Request**

```json
{
  "name": "Simulación Laboral – Diciembre 2026",
  "startsOn": "2026-12-07",
  "endsOn": "2027-01-15",
  "demoDayOn": null
}
```

**Response `201`**: el elemento creado.

**Errores:** `400 VALIDATION_ERROR` (`endsOn` anterior a `startsOn`, o `demoDayOn` fuera del rango).

### `GET /admin/metrics` 🔒 ADMIN — prioridad baja

Indicadores del research para el Demo Day. Reemplaza las consultas manuales en Supabase. Puede quedar para el final.

**Query:** `firstChallengeOnly` (por defecto `true`: cuenta solo el primer desafío de cada decisor, para no sesgar la
comparación de variantes).

**Response `200`**

```json
{
  "generatedAt": "2026-11-10T12:00:00Z",
  "formVariants": [
    {
      "code": "free_text",
      "sessions": 14,
      "submitted": 9,
      "abandoned": 5,
      "averageInitialQualityScore": 2.8,
      "abandonmentByField": [
        {
          "fieldKey": "description",
          "count": 4
        },
        {
          "fieldKey": "title",
          "count": 1
        }
      ]
    },
    {
      "code": "guided",
      "sessions": 13,
      "submitted": 10,
      "abandoned": 3,
      "averageInitialQualityScore": 3.9,
      "abandonmentByField": [
        {
          "fieldKey": "expected_outcome",
          "count": 2
        },
        {
          "fieldKey": "affected",
          "count": 1
        }
      ]
    }
  ],
  "emails": [
    {
      "emailType": "ABANDONMENT_RECOVERY",
      "variantCode": "copy_a_2h",
      "sent": 4,
      "opened": 3,
      "clicked": 2
    },
    {
      "emailType": "APPROVAL",
      "variantCode": null,
      "sent": 12,
      "opened": 11,
      "clicked": 8
    }
  ],
  "reviews": {
    "medianHoursToFirstReview": 20.5,
    "byDecision": {
      "APPROVED": 12,
      "REJECTED": 2,
      "CONTEXT_REQUESTED": 5
    }
  },
  "meetings": {
    "byPurpose": {
      "DESCRIBE_CHALLENGE": 4,
      "LEARN_MORE": 3,
      "REVIEW_FOLLOW_UP": 2
    },
    "byStatus": {
      "REQUESTED": 1,
      "SCHEDULED": 2,
      "COMPLETED": 5,
      "CANCELLED": 1
    }
  }
}
```

| Bloque         | Pieza    | Fuente                                                                                         |
|----------------|----------|------------------------------------------------------------------------------------------------|
| `formVariants` | 2 y 4    | `form_sessions`, `challenges.initial_quality_score`                                            |
| `emails`       | 3, 4 y 6 | `email_messages` (para comparar variantes conviene usar `clicked`, más confiable que `opened`) |
| `reviews`      | 3        | `challenges.submitted_at`, `reviewed_at`                                                       |
| `meetings`     | 5        | `meetings`                                                                                     |

Un intento cuenta como abandonado si no tiene `completed_at` y su última actividad tiene más de 2 horas.

---

## 14. Webhook de Brevo

### `POST /public/webhooks/brevo`

Recibe los eventos de los emails enviados. **Público pero autenticado con un secreto compartido**, configurado en Brevo
al crear el webhook (por ejemplo, un token en la URL o en un encabezado, según lo que permita su panel). Sin secreto
válido → `401`.

Con secreto válido devuelve **siempre `200`**, aunque el evento se ignore: Brevo reintenta ante cualquier otro código.

El backend busca el email por el `message-id` del evento en `email_messages.provider_message_id` y actualiza:

| Evento de Brevo                  | Cambio                                   |
|----------------------------------|------------------------------------------|
| Apertura                         | `first_opened_at`, solo si estaba vacío  |
| Clic                             | `first_clicked_at`, solo si estaba vacío |
| Rebote, bloqueo o email inválido | `status = FAILED` y `error_message`      |
| Otros                            | Se ignoran                               |

Los nombres exactos de los eventos y del campo `message-id` se toman de la documentación del webhook transaccional de
Brevo al implementarlo.

---

## 15. Tracking (opcional)

Tabla: `tracking_events`. **Se implementa si el tiempo alcanza.** La tabla ya existe en el esquema, así que no hace
falta una migración.

### `POST /public/events`

Registra un evento de comportamiento. No requiere autenticación (el dashboard es público). Requiere el header
`X-Visitor-Id`.

**Request**

```json
{
  "eventName": "field_completed",
  "formSessionId": "9b2e5c1a-3f4d-4e6a-9b7c-1d2e3f4a5b6c",
  "properties": {
    "field": "affected",
    "duration_ms": 41000
  }
}
```

- `visitorId` sale del header, y `decisionMakerId` del token si lo hay. Nunca del body.
- Solo se aceptan los eventos del catálogo. `properties` es libre y hasta 2 KB.

**Response `202`** (sin body)

**Errores:** `400 VALIDATION_ERROR` (evento fuera del catálogo o sin `X-Visitor-Id`) · `429 RATE_LIMITED`.

| Evento                                                                      | Lo registra                          | Mínimo indispensable |
|-----------------------------------------------------------------------------|--------------------------------------|----------------------|
| `dashboard_viewed`                                                          | Frontend                             | ✔                   |
| `cta_clicked`                                                               | Frontend                             | ✔                   |
| `confirmation_viewed`                                                       | Frontend                             | ✔                   |
| `form_started`, `field_focused`, `field_completed`                          | Frontend                             |                      |
| `login_requested`, `login_completed`, `form_submitted`, `meeting_requested` | Backend, desde sus propios endpoints |                      |

Con los tres eventos mínimos se cubren las preguntas de la Pieza 1 (dashboard → clic) y la Pieza 3 (qué pantalla de
confirmación vio).

---

## 16. Procesos internos (sin endpoint)

Tareas que el backend ejecuta solo. No las consume el frontend, pero son parte del funcionamiento.

| Proceso                                | Frecuencia               | Qué hace                                                                                                                                                                                                                                           | Tablas                               |
|----------------------------------------|--------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------|
| Envío de emails                        | Cada minuto              | Toma los emails `SCHEDULED` con `scheduled_for <= now()`, los envía con Brevo y guarda `provider_message_id` y `sent_at`. Si falla, `FAILED` con `error_message`                                                                                   | `email_messages`                     |
| Detección de abandonos (Pieza 4)       | Cada 15 minutos          | Busca sesiones sin enviar, con más de 2 horas sin actividad, de decisores con email verificado y consentimiento, sin un email de recuperación previo. Programa un `ABANDONMENT_RECOVERY` con la variante de copy y de espera que se esté testeando | `form_sessions`, `email_messages`    |
| Sincronización del dashboard (Pieza 1) | 1 vez por día            | Lee la web pública de No Country y reemplaza los datos de la simulación actual y sus proyectos. Si falla, conserva los últimos datos                                                                                                               | `simulations`, `simulation_projects` |
| Limpieza de tokens                     | 1 vez por día (opcional) | Borra los magic links vencidos hace más de 7 días                                                                                                                                                                                                  | `magic_link_tokens`                  |

Para la sincronización, se lee solo la página principal de simulaciones: las páginas de cada equipo tienen datos
personales y no se usan.

---

## 17. Emails que dispara cada acción

| Acción                       | Endpoint o proceso                                               | `email_type`                                 | Vínculo           |
|------------------------------|------------------------------------------------------------------|----------------------------------------------|-------------------|
| Pide acceso                  | `POST /public/auth/magic-link`                                   | `MAGIC_LINK`                                 | —                 |
| Envía un desafío             | `POST /form/{id}/submit` · `POST /admin/meetings/{id}/challenge` | `SUBMISSION_CONFIRMATION`                    | `challenge_id`    |
| Reenvía un desafío           | `POST /challenges/{id}/resubmit`                                 | `SUBMISSION_CONFIRMATION`                    | `challenge_id`    |
| Abandona el formulario       | Detección de abandonos                                           | `ABANDONMENT_RECOVERY`                       | `form_session_id` |
| El admin empieza la revisión | `POST /admin/challenges/{id}/start-review`                       | `REVIEW_STARTED`                             | `challenge_id`    |
| El admin decide              | `POST /admin/challenges/{id}/review`                             | `APPROVAL` · `REJECTION` · `CONTEXT_REQUEST` | `challenge_id`    |
| El admin asigna simulación   | `POST /admin/challenges/{id}/assign-simulation`                  | `SIMULATION_ASSIGNED`                        | `challenge_id`    |
| El admin agenda una llamada  | `POST /admin/meetings/{id}/schedule`                             | `MEETING_SCHEDULED`                          | `meeting_id`      |

Los avisos a los admins (nueva solicitud de llamada, reprogramación, cancelación) se envían por Brevo pero no se
registran en `email_messages`.

Los emails que llevan a una página con sesión (por ejemplo, "Ver el estado de tu desafío") apuntan al listado del
decisor. Si no tiene sesión, el frontend le pide el email y el magic link lo deja en esa página.

---

## 18. Operación

| Método | Ruta                | Descripción                                                               |
|--------|---------------------|---------------------------------------------------------------------------|
| `GET`  | `/public/ping`      | El proceso responde. No toca la base                                      |
| `GET`  | `/public/db-status` | Estado de la conexión con PostgreSQL. `200` conectado, `503` sin conexión |

### `GET /public/db-status`

**Response `200`**

```json
{
  "status": "UP",
  "latencyMs": 42,
  "timestamp": "2026-10-20T19:00:00Z"
}
```

**Response `503`**

```json
{
  "status": "DOWN",
  "sqlState": "08001",
  "timestamp": "2026-10-20T19:00:00Z"
}
```

No se exponen datos de infraestructura (URL, usuario, pool). El detalle queda en el log del servidor.

---

## 19. Estado de implementación

Semanas de la simulación: S2 (19–25 oct) · S3 (26 oct–1 nov) · S4 (2–8 nov) · S5 (9–13 nov, Demo Day el 13). El orden
sigue el de las Piezas: el documento pide testearlas en secuencia.

| Endpoint                                                                             | Pieza    | Semana | Prioridad | Estado |
|--------------------------------------------------------------------------------------|----------|--------|-----------|--------|
| `GET /public/ping` · `GET /public/db-status`                                         | —        | S2     | Alta      | ☐     |
| `GET /public/dashboard` + sincronización                                             | 1        | S2     | Alta      | ☐     |
| `POST /public/auth/magic-link` · `GET` · `POST /verify`                              | —        | S2     | Alta      | ☐     |
| `GET /me` · `PATCH /me`                                                              | —        | S2     | Alta      | ☐     |
| `GET /form` · `PATCH /form/{id}` · `POST /form/{id}/submit`                          | 2        | S2     | Alta      | ☐     |
| Envío de emails (proceso)                                                            | 3        | S3     | Alta      | ☐     |
| `POST /admin/auth/login` · `GET /admin/auth/me`                                      | —        | S3     | Alta      | ☐     |
| `GET /admin/challenges` · `GET /admin/challenges/{id}`                               | —        | S3     | Alta      | ☐     |
| `POST /admin/challenges/{id}/start-review` · `/review` · `GET /admin/quality-rubric` | 3        | S3     | Alta      | ☐     |
| `GET /challenges` · `GET /challenges/{id}`                                           | 3        | S3     | Alta      | ☐     |
| `POST /public/webhooks/brevo`                                                        | 3 y 6    | S3     | Alta      | ☐     |
| Detección de abandonos (proceso)                                                     | 4        | S3     | Media     | ☐     |
| `POST /challenges/{id}/resubmit`                                                     | 5        | S4     | Alta      | ☐     |
| `POST /meetings` · `GET /meetings` · `/reschedule` · `/cancel`                       | 5        | S4     | Alta      | ☐     |
| `GET /admin/meetings` · `/schedule` · `/complete` · `/cancel` · `/challenge`         | 5        | S4     | Alta      | ☐     |
| `GET /admin/simulations` · `POST /admin/simulations` · `/assign-simulation`          | 6        | S4     | Media     | ☐     |
| `POST /public/auth/google`                                                           | —        | S4     | Media     | ☐     |
| `GET /admin/metrics`                                                                 | Todas    | S5     | Baja      | ☐     |
| `POST /public/events`                                                                | 1, 2 y 3 | S5     | Opcional  | ☐     |

🔒 = requiere autenticación · ADMIN = requiere token de admin
