import os

/// `log stream --predicate 'subsystem == "com.keynav.app"' --level info`
let log = Logger(subsystem: "com.keynav.app", category: "keynav")
