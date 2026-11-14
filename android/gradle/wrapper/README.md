# Gradle Wrapper

This directory intentionally contains only `gradle-wrapper.properties`. The
`gradle-wrapper.jar` is **not** committed. Generate it (and the `gradlew` /
`gradlew.bat` scripts) with a locally installed Gradle 8.7:

```
gradle wrapper --gradle-version 8.7 --distribution-type bin
```

Run that from the `android/` directory of this project, then commit the
generated `gradlew`, `gradlew.bat`, `gradle/wrapper/gradle-wrapper.jar` and
this properties file together. After that, `./gradlew assembleDebug` works.
