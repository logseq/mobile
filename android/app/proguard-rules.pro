# Firebase discovers ML Kit registrars by name and calls their no-arg constructors.
-keep class * implements com.google.firebase.components.ComponentRegistrar {
    public <init>();
}

# The formula parser instantiates this macro provider and invokes its methods reflectively.
-keep class org.scilab.forge.jlatexmath.NewCommandMacro { *; }
