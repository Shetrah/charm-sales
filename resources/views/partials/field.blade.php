<label for="{{ $id ?? $name }}" data-i18n="{{ $label }}">{{ __($label) }}</label>
@if(($type ?? 'text')==='textarea')<textarea id="{{ $id ?? $name }}" name="{{ $name }}" rows="3" @if($required ?? false) required @endif maxlength="10000"></textarea>
@else<input id="{{ $id ?? $name }}" name="{{ $name }}" type="{{ $type ?? 'text' }}" @if($required ?? false) required @endif @if(isset($min)) min="{{ $min }}" @endif @if(isset($step)) step="{{ $step }}" @endif @if(($type ?? '')==='password') minlength="12" autocomplete="new-password" @endif>
@endif
