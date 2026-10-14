# UXFlow – Carga de Desafíos

MVP del flujo de carga de desafíos para **No Country**: dashboard público, formulario con variantes A/B, emails automatizados y panel de admin, construido para validar con usuarios reales cómo los decisores suben proyectos a la simulación laboral.

> Proyecto desarrollado durante la **Simulación Laboral Abierta de No Country** (12 de octubre al 16 de noviembre de 2026).

---

## Sobre el proyecto

No Country permite que empresas, docentes y líderes suban desafíos reales para que equipos de la comunidad los ejecuten durante sus simulaciones laborales. La carga de desafíos todavía no escala de forma consistente, y gran parte del flujo posterior al primer envío no está definido.

Este repositorio contiene un MVP independiente, inspirado en la plataforma de No Country, que se usa para:

- **Investigar** las motivaciones y fricciones de los decisores.
- **Testear** cada pieza del flujo con usuarios reales y medir su comportamiento.
- **Validar** con datos una versión del flujo lista para implementar.
- **Cargar desafíos reales** que puedan usarse en próximas simulaciones.

## Qué contiene

El MVP cubre únicamente el flujo de carga de desafíos, no la plataforma completa de No Country:

| Módulo | Descripción |
| --- | --- |
| Dashboard público | Proyectos activos de la simulación con cantidad de equipos y participantes. |
| Formulario de carga | Carga de desafíos sin registro previo, con variantes A/B (texto libre vs. preguntas guiadas) y guardado parcial. |
| Emails del flujo | Confirmación, recuperación de abandonos, pedido de contexto adicional y aprobación. |
| Panel de admin | Revisión, calificación y aprobación de los desafíos recibidos. |
| Vista del decisor | Seguimiento del estado y progreso del desafío mediante acceso por enlace (magic link). |
| Métricas | Registro de eventos del embudo para respaldar las decisiones de diseño con datos. |
| Exportación | Salida de los desafíos aprobados en un formato compatible con No Country. |

## Etapas del proyecto

1. **Descubrimiento:** entrevistas con decisores para mapear motivaciones y fricciones por perfil.
2. **Testing del flujo:** cada pieza se testea con al menos 5 usuarios reales, se itera y se documenta.
3. **Activación y entrega:** desafíos reales cargados en el sistema y presentación en el Demo Day.

## Stack

> A definir.

## Instalación y uso

> Se completará cuando el stack y la estructura del proyecto estén definidos.

## Estado

🚧 En desarrollo.

## Privacidad

El sistema almacena datos de contacto y descripciones de desafíos de decisores reales. Los datos se recolectan con consentimiento explícito y se tratan de acuerdo con la Ley 25.326 de Protección de Datos Personales (Argentina).