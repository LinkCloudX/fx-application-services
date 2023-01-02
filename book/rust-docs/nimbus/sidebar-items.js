window.SIDEBAR_ITEMS = {"constant":[["DB_KEY_APP_VERSION",""],["DB_KEY_INSTALLATION_DATE",""],["DB_KEY_UPDATE_DATE",""],["SCHEMA_VERSION","This is the currently supported major schema version."]],"enum":[["EnrollmentStatus",""],["RandomizationUnit",""]],"fn":[["evaluate_enrollment","Determine the enrolment status for an experiment."],["ffi_nimbus_256f_rustbuffer_alloc",""],["ffi_nimbus_256f_rustbuffer_free",""],["ffi_nimbus_256f_rustbuffer_from_bytes",""],["ffi_nimbus_256f_rustbuffer_reserve",""]],"macro":[["uniffi_reexport_scaffolding",""]],"mod":[["error","Not complete yet This is where the error definitions can go TODO: Implement proper error handling, this would include defining the error enum, impl std::error::Error using `thiserror` and ensuring all errors are handled appropriately"],["persistence","Our storage abstraction, currently backed by Rkv."],["versioning","Nimbus SDK App Version Comparison"]],"struct":[["AppContext","The `AppContext` object represents the parameters and characteristics of the consuming application that we are interested in for targeting purposes. The `app_name` and `channel` fields are not optional as they are expected to be provided by all consuming applications as they are used in the top-level targeting that help to ensure that an experiment is only processed by the correct application."],["AvailableExperiment",""],["AvailableRandomizationUnits",""],["Branch",""],["BucketConfig",""],["EnrolledExperiment",""],["Experiment",""],["ExperimentBranch",""],["FeatureConfig",""],["NimbusClient","Nimbus is the main struct representing the experiments state It should hold all the information needed to communicate a specific user’s experimentation status"],["NimbusStringHelper",""],["NimbusTargetingHelper",""],["RemoteSettingsConfig","Optional custom configuration Currently includes the following:"],["TargetingAttributes",""]]};