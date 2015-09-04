/**
 * Skadi.d Web Framework
 *
 * Forked from: https://github.com/mbierlee/poodinis
 * Authors:  Mike Bierlee, Faianca
 * Copyright: Copyright (c) 2015  Mike Bierlee, Faianca
 * License: MIT License, see LICENSE
 */
module skadi.container.container;

import std.string;
import std.algorithm;
import std.concurrency;

debug {
	import std.stdio;
}

public import skadi.container.registration;
public import skadi.container.inject;

/**
 * Exception thrown when errors occur while resolving a type in a dependency container.
 */
class ResolveException : Exception
{
	this(string message, TypeInfo resolveType)
	{
		super(format("Exception while resolving type %s: %s", resolveType.toString(), message));
	}
}

/**
 * Exception thrown when errors occur while registering a type in a dependency container.
 */
class RegistrationException : Exception
{
	this(string message, TypeInfo registrationType)
	{
		super(format("Exception while registering type %s: %s", registrationType.toString(), message));
	}
}

/**
 * Options which influence the process of registering dependencies
 */
public enum RegistrationOptions
{
	/**
	 * When registering a type by its supertype, providing this option will also register
	 * a linked registration to the type itself.
	 *
	 * This allows you to resolve that type both by super type and concrete type using the
	 * same registration scope (and instance managed by this scope).
	 */
	ADD_CONCRETE_TYPE_REGISTRATION
}

/**
 * The dependency container maintains all dependencies registered with it.
 *
 * Dependencies registered by a container can be resolved as long as they are still registered with the container.
 * Upon resolving a dependency, an instance is fetched according to a specific scope which dictates how instances of
 * dependencies are created. Resolved dependencies will be injected before being returned.
 *
 * In most cases you want to use a global singleton dependency container provided by getInstance() to manage all dependencies.
 * You can still create new instances of this class for exceptional situations.
 */
synchronized class Container
{
	private Registration[][TypeInfo] registrations;

	private Registration[] injectStack;

	/**
	 * Register a dependency by concrete class type.
	 *
	 * A dependency registered by concrete class type can only be resolved by concrete class type.
	 * No qualifiers can be used when resolving dependencies which are registered by concrete type.
	 *
	 * The default registration scope is "single instance" scope.
	 *
	 * Returns:
	 * A registration is returned which can be used to change the registration scope.
	 */
	public Registration register(ConcreteType)()
	{
		return register!(ConcreteType, ConcreteType)();
	}

	/**
	 * Register a dependency by super type.
	 *
	 * A dependency registered by super type can only be resolved by super type. A qualifier is typically
	 * used to resolve dependencies registered by super type.
	 *
	 * The default registration scope is "single instance" scope.
	 *
	 * See_Also: singleInstance, newInstance, existingInstance, RegistrationOptions
	 */
	public Registration register(SuperType, ConcreteType : SuperType, RegistrationOptionsTuple...)(RegistrationOptionsTuple options)
	{
		TypeInfo registeredType = typeid(SuperType);
		TypeInfo_Class concreteType = typeid(ConcreteType);

		debug(skadiVerbose) {
			writeln(format("DEBUG: Register type %s (as %s)", concreteType.toString(), registeredType.toString()));
		}

		auto existingRegistration = getExistingRegistration(registeredType, concreteType);
		if (existingRegistration) {
			return existingRegistration;
		}

		auto newRegistration = new InjectedRegistration!ConcreteType(registeredType, this);
		newRegistration.singleInstance();

		if (hasOption(options, RegistrationOptions.ADD_CONCRETE_TYPE_REGISTRATION)) {
			static if (!is(SuperType == ConcreteType)) {
				auto concreteTypeRegistration = register!ConcreteType;
				concreteTypeRegistration.linkTo(newRegistration);
			} else {
				throw new RegistrationException("Option ADD_CONCRETE_TYPE_REGISTRATION cannot be used when registering a concrete type registration", concreteType);
			}
		}

		registrations[registeredType] ~= cast(shared(Registration)) newRegistration;
		return newRegistration;
	}

	private bool hasOption(RegistrationOptionsTuple...)(RegistrationOptionsTuple options, RegistrationOptions option)
	{
		foreach(presentOption ; options) {
			if (presentOption == option) {
				return true;
			}
		}

		return false;
	}

	private Registration getExistingRegistration(TypeInfo registrationType, TypeInfo qualifierType)
	{
		auto existingCandidates = registrationType in registrations;
		if (existingCandidates) {
			return getRegistration(cast(Registration[]) *existingCandidates, qualifierType);
		}

		return null;
	}

	private Registration getRegistration(Registration[] candidates, TypeInfo concreteType)
	{
		foreach(existingRegistration ; candidates) {
			if (existingRegistration.instantiatableType == concreteType) {
				return existingRegistration;
			}
		}

		return null;
	}

	/**
	 * Resolve dependencies.
	 *
	 * Dependencies can only resolved using this method if they are registered by concrete type or the only
	 * concrete type registered by super type.
	 *
	 * Resolved dependencies are automatically injected before being returned.
	 *
	 * Returns:
	 * An instance is returned which is created according to the registration scope with which they are registered.
	 *
	 * Throws:
	 * ResolveException when type is not registered.

	 * You need to use the resolve method which allows you to specify a qualifier.
	 */
	public RegistrationType resolve(RegistrationType)()
	{
		return resolve!(RegistrationType, RegistrationType)();
	}

	/**
	 * Resolve dependencies using a qualifier.
	 *
	 * Dependencies can only resolved using this method if they are registered by super type.
	 *
	 * Resolved dependencies are automatically injected before being returned.
	 *
	 * Returns:
	 * An instance is returned which is created according to the registration scope with which they are registered.
	 *
	 * Throws:
	 * ResolveException when type is not registered or there are multiple candidates available for type.
	 */
	public QualifierType resolve(RegistrationType, QualifierType : RegistrationType)()
	{
		TypeInfo resolveType = typeid(RegistrationType);
		TypeInfo qualifierType = typeid(QualifierType);

		debug(skadiVerbose) {
			writeln("DEBUG: Resolving type " ~ resolveType.toString() ~ " with qualifier " ~ qualifierType.toString());
		}

		auto candidates = resolveType in registrations;
		if (!candidates) {
			throw new ResolveException("Type not registered.", resolveType);
		}

		Registration registration = getQualifiedRegistration(resolveType, qualifierType, cast(Registration[]) *candidates);
		return resolveInjectedInstance!QualifierType(registration);
	}

	private QualifierType resolveInjectedInstance(QualifierType)(Registration registration)
	{
		QualifierType instance;
		if (!(cast(Registration[]) injectStack).canFind(registration)) {
			injectStack ~= cast(shared(Registration)) registration;
			instance = cast(QualifierType) registration.getInstance(new InjectInstantiationContext());
			injectStack = injectStack[0 .. $-1];
		} else {
			auto injectContext = new InjectInstantiationContext();
			injectContext.injectInstance = false;
			instance = cast(QualifierType) registration.getInstance(injectContext);
		}
		return instance;
	}

	/**
	 * Resolve all dependencies registered to a super type.
	 *
	 * Returns:
	 * An array of injected instances is returned. The order is undetermined.
	 */
	public RegistrationType[] resolveAll(RegistrationType)()
	{
		RegistrationType[] instances;
		TypeInfo resolveType = typeid(RegistrationType);

		auto qualifiedRegistrations = resolveType in registrations;
		if (!qualifiedRegistrations) {
			throw new ResolveException("Type not registered.", resolveType);
		}

		foreach(registration ; cast(Registration[]) *qualifiedRegistrations) {
			instances ~= resolveInjectedInstance!RegistrationType(registration);
		}

		return instances;
	}

	private Registration getQualifiedRegistration(TypeInfo resolveType, TypeInfo qualifierType, Registration[] candidates)
	{
		if (resolveType == qualifierType) {
			if (candidates.length > 1) {
				string candidateList = candidates.toConcreteTypeListString();
				throw new ResolveException("Multiple qualified candidates available: " ~ candidateList ~ ". Please use a qualifier.", resolveType);
			}

			return candidates[0];
		}

		return getRegistration(candidates, qualifierType);
	}

	/**
	 * Clears all dependency registrations managed by this container.
	 */
	public void clearAllRegistrations()
	{
		registrations.destroy();
	}

	/**
	 * Removes a registered dependency by type.
	 *
	 * A dependency can be removed either by super type or concrete type, depending on how they are registered.
	 *
	 */
	public void removeRegistration(RegistrationType)()
	{
		registrations.remove(typeid(RegistrationType));
	}

	/**
	 * Returns a global singleton instance of a dependency container.
	 */
	public static shared(Container) getInstance()
	{
		static shared Container instance;
		if (instance is null) {
			instance = new Container();
		}
		return instance;
	}

}
