/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

//! Helpers for components to "handle" errors.

/// Describes what error reporting action should be taken.
#[derive(Debug, Default)]
pub struct ErrorReporting {
    /// If Some(level), will write a log message at that level.
    log_level: Option<log::Level>,
    /// If Some(report_class) will call the error reporter with details.
    report_class: Option<String>,
}

/// Specifies how an "internal" error is converted to an "external" public error and
/// any logging or reporting that should happen.
pub struct ErrorHandling<E> {
    /// The external error that should be returned.
    pub err: E,
    /// How the error should be reported.
    pub reporting: ErrorReporting,
}

impl<E> ErrorHandling<E> {
    /// Create an ErrorHandling instance with an error conversion.
    ///
    /// ErrorHandling instance are created using a builder-style API.  This is always the first
    /// function in the chain, optionally followed by `log()`, `report()`, etc.
    pub fn convert(err: E) -> Self {
        Self {
            err,
            reporting: ErrorReporting::default(),
        }
    }

    /// Add logging to an ErrorHandling instance
    pub fn log(self, level: log::Level) -> Self {
        Self {
            err: self.err,
            reporting: ErrorReporting {
                log_level: Some(level),
                ..self.reporting
            },
        }
    }

    /// Add reporting to an ErrorHandling instance
    pub fn report(self, report_class: impl Into<String>) -> Self {
        Self {
            err: self.err,
            reporting: ErrorReporting {
                report_class: Some(report_class.into()),
                ..self.reporting
            },
        }
    }

    // Convenience functions for the most common error reports

    /// Add reporting to an ErrorHandling instance and also log an Error
    pub fn log_warning(self) -> Self {
        self.log(log::Level::Warn)
    }

    /// Add reporting to an ErrorHandling instance and also log an Error
    pub fn report_error(self, report_class: impl Into<String>) -> Self {
        Self {
            err: self.err,
            reporting: ErrorReporting {
                log_level: Some(log::Level::Error),
                report_class: Some(report_class.into()),
            },
        }
    }
}

/// Handle the specified "internal" error, taking any logging or error
/// reporting actions and converting the error to the public error.
/// Called by our `handle_error` macro so needs to be public.
pub fn convert_log_report_error<IE, EE>(e: IE) -> EE
where
    IE: Into<ErrorHandling<EE>> + std::error::Error,
    EE: std::error::Error,
{
    let log_message = e.to_string();
    let handling = e.into();
    let reporting = handling.reporting;
    if let Some(level) = reporting.log_level {
        log::log!(level, "{}", log_message);
    }
    if let Some(report_class) = reporting.report_class {
        // notify the error reporter if the feature is enabled.
        // XXX - should we arrange for the `report_class` to have the
        // original crate calling this as a prefix, or will we still be
        // able to identify that?
        #[cfg(feature = "reporting")]
        crate::report_error(report_class, log_message);
        #[cfg(not(feature = "reporting"))]
        let _ = report_class; // avoid clippy warning when feature's not enabled.
    }
    handling.err
}
