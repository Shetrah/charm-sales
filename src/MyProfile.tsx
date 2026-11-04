import { useState, type ReactNode } from 'react';
import { useQueryClient } from '@tanstack/react-query';
import { ArrowUpRight, BadgeCheck, BriefcaseBusiness, CheckCircle2, Globe2, Languages, LockKeyhole, Mail, MapPin, Moon, Phone, ShieldCheck, Sun, UserRound, WalletCards } from 'lucide-react';
import type { Profile } from './lib/data';
import { StaffAvatar } from './Team';
import { MediaUpload } from './MediaUpload';
import { ErrorNotice, Field, PasswordField } from './components';
import { rpc, supabase } from './lib/supabase';
import { usePreferences } from './i18n';

const workspaceByRole: Record<Profile['role'], string> = {
 admin: 'workspaceManagement',
 salesperson: 'workspaceSales',
 finance_officer: 'workspaceFinance',
 logistics_manager: 'workspaceLogistics',
};

export function MyProfile({profile,scope}:{profile:Profile;scope:string}) {
 const {t,theme,language,toggleTheme,toggleLanguage}=usePreferences();
 const qc=useQueryClient();
 const [name,setName]=useState(profile.name);
 const [phone,setPhone]=useState(profile.phone??'');
 const [territory,setTerritory]=useState(profile.territory??'');
 const [currentPassword,setCurrentPassword]=useState('');
 const [newPassword,setNewPassword]=useState('');
 const [confirmPassword,setConfirmPassword]=useState('');
 const [busy,setBusy]=useState(false);
 const [error,setError]=useState<unknown>();
 const [passwordError,setPasswordError]=useState<unknown>();
 const [saved,setSaved]=useState(false);
 const [passwordSaved,setPasswordSaved]=useState(false);
 const role=profile.role;
 const display=(value:string|null|undefined)=>value?.trim()||t('notProvided');
 const refresh=()=>{void qc.invalidateQueries({queryKey:[scope,'profile']});setSaved(true);};

 return <main className="content my-profile">
  <div className="page-heading profile-page-heading"><div><span className="eyebrow">CHARM KENYA / {t('myProfile')}</span><h1>{t('profileTitle')}</h1><p>{t('profileIntro')}</p></div></div>

  <section className="profile-cover">
   <div className="profile-cover-art"><div className="profile-cover-orbit orbit-a"/><div className="profile-cover-orbit orbit-b"/><span className="profile-cover-dot dot-a"/><span className="profile-cover-dot dot-b"/><span className="profile-cover-dot dot-c"/><div className="profile-cover-caption"><span className="profile-cover-mark"><BriefcaseBusiness size={15}/></span><span>CHARM <small>COMPANY HUB</small></span></div><div className="profile-cover-welcome"><span>{t('yourWorkspace')}</span><strong>{t(workspaceByRole[role])}</strong></div></div>
   <div className="profile-hero"><div className="profile-avatar-wrap"><StaffAvatar name={name||profile.name} path={profile.photo_path} className="profile-avatar" label={name||profile.name}/><span className="profile-avatar-check"><BadgeCheck size={17}/></span></div><div className="profile-identity-copy"><span className="eyebrow">{t(role)}</span><h2>{name||profile.name}</h2><p><Mail size={14}/>{profile.email}</p></div><div className={`profile-status ${profile.active?'is-active':'is-inactive'}`}><i/>{t(profile.active?'active':'inactive')}</div></div>
   <div className="profile-cover-footer"><span><WalletCards size={15}/>{profile.staff_code||`#${profile.id}`}</span><span><MapPin size={15}/>{display(territory)}</span><span><ShieldCheck size={15}/>{t('signedInAccount')}</span></div>
  </section>

  <div className="profile-edit-grid">
   <section className="card profile-edit-card"><div className="profile-section-heading"><div><span className="eyebrow">{t('personalDetails')}</span><h2>{t('editYourDetails')}</h2><p>{t('profileFormHint')}</p></div><span className="profile-section-icon"><UserRound size={19}/></span></div>
    <div className="profile-photo-row"><StaffAvatar name={name||profile.name} path={profile.photo_path} className="profile-photo-preview" label={name||profile.name}/><div className="profile-photo-copy"><strong>{t('profilePhoto')}</strong><span>{t('staffPhotoHint')}</span></div><div className="profile-photo-action"><MediaUpload kind="staff" id={profile.id} path={profile.photo_path} label="uploadStaffPhoto" removeLabel="removeStaffPhoto" onSaved={refresh}/></div></div>
    <form className="profile-form" onSubmit={async e=>{e.preventDefault();setBusy(true);setError(undefined);setSaved(false);try{await rpc('update_own_profile',{p_name:name,p_phone:phone||null,p_territory:territory||null});setSaved(true);await qc.invalidateQueries({queryKey:[scope,'profile']});}catch(err){setError(err);}finally{setBusy(false);}}}>
     <div className="profile-form-grid"><Field label="name"><input required maxLength={200} value={name} onChange={e=>setName(e.target.value)}/></Field><Field label="email"><input value={profile.email} disabled readOnly/></Field><Field label="phone"><input type="tel" maxLength={40} value={phone} onChange={e=>setPhone(e.target.value)}/></Field><Field label="territory"><input maxLength={200} value={territory} onChange={e=>setTerritory(e.target.value)}/></Field></div>
     {error!==undefined&&error!==null&&<ErrorNotice error={error}/ >}{saved&&<div className="notice" role="status">{t('profileSaved')}</div>}<div className="profile-form-footer"><span><ShieldCheck size={15}/>{t('profilePrivacy')}</span><button className="primary" disabled={busy}>{t(busy?'saving':'save')}<ArrowUpRight size={16}/></button></div>
    </form>
   </section>

   <aside className="profile-side">
    <section className="card profile-summary"><div className="profile-summary-head"><span className="profile-summary-icon"><BriefcaseBusiness size={17}/></span><div><span className="eyebrow">{t('accountOverview')}</span><h2>{t('employmentIdentity')}</h2></div><BadgeCheck size={19}/></div>
     <ProfileInfo icon={<Mail size={16}/>} label={t('email')} value={profile.email}/><ProfileInfo icon={<Phone size={16}/>} label={t('phone')} value={display(phone)}/><ProfileInfo icon={<MapPin size={16}/>} label={t('territory')} value={display(territory)}/><ProfileInfo icon={<WalletCards size={16}/>} label={t('staffCode')} value={profile.staff_code||`#${profile.id}`}/><ProfileInfo icon={<ShieldCheck size={16}/>} label={t('role')} value={t(role)}/><ProfileInfo icon={<CheckCircle2 size={16}/>} label={t('accountStatus')} value={t(profile.active?'active':'inactive')} status={profile.active}/>
    </section>
   <section className="card profile-preferences"><div className="profile-section-heading compact"><div><span className="eyebrow">{t('profileSecurity')}</span><h2>{t('changePassword')}</h2><p>{t('profilePasswordHint')}</p></div><span className="profile-section-icon"><LockKeyhole size={18}/></span></div>
     <form className="profile-password-form" onSubmit={async e=>{e.preventDefault();setPasswordError(undefined);setPasswordSaved(false);if(newPassword.length<6){setPasswordError(new Error('passwordTooShort'));return;}if(newPassword!==confirmPassword){setPasswordError(new Error('passwordMismatch'));return;}if(!supabase){setPasswordError(new Error('configuration'));return;}setBusy(true);try{const verified=await supabase.auth.signInWithPassword({email:profile.email,password:currentPassword});if(verified.error)throw new Error('currentPasswordIncorrect');const updated=await supabase.auth.updateUser({password:newPassword});if(updated.error)throw updated.error;setCurrentPassword('');setNewPassword('');setConfirmPassword('');setPasswordSaved(true);}catch(err){setPasswordError(err);}finally{setBusy(false);}}}>
      <PasswordField label="currentPassword" required autoComplete="current-password" value={currentPassword} onChange={e=>setCurrentPassword(e.target.value)}/>
      <PasswordField label="newPassword" required minLength={6} autoComplete="new-password" value={newPassword} onChange={e=>setNewPassword(e.target.value)}/>
      <PasswordField label="confirmNewPassword" required minLength={6} autoComplete="new-password" value={confirmPassword} onChange={e=>setConfirmPassword(e.target.value)}/>
      {passwordError!==undefined&&passwordError!==null&&<ErrorNotice error={passwordError}/ >}{passwordSaved&&<div className="notice" role="status">{t('passwordChanged')}</div>}
      <button className="primary profile-password-submit" disabled={busy}>{t(busy?'saving':'changePassword')}<ArrowUpRight size={15}/></button>
     </form>
     <div className="profile-preference-actions">
     <button type="button" className="profile-pref-row" onClick={toggleLanguage}><span className="profile-pref-icon teal"><Globe2 size={16}/></span><span><strong>{t('languageLabel')}</strong><small>{language==='en'?'English':'简体中文'}</small></span><span className="profile-pref-value"><Languages size={14}/>{language==='en'?'中文':'English'}</span></button>
     <button type="button" className="profile-pref-row" onClick={toggleTheme}><span className="profile-pref-icon">{theme==='dark'?<Sun size={16}/>:<Moon size={16}/>}</span><span><strong>{t('themeLabel')}</strong><small>{t(theme==='dark'?'darkMode':'lightMode')}</small></span><span className="profile-pref-value">{t(theme==='dark'?'lightMode':'darkMode')}</span></button>
     </div>
    </section>
    <div className="profile-note"><span className="profile-note-icon"><ShieldCheck size={18}/></span><div><strong>{t('profilePrivacy')}</strong><p>{t('profilePrivacyHint')}</p></div></div>
   </aside>
  </div>
 </main>;
}

function ProfileInfo({icon,label,value,status}:{icon:ReactNode;label:string;value:string;status?:boolean}) {
 return <div className="profile-info-row"><span className="profile-info-icon">{icon}</span><span className="profile-info-copy"><small>{label}</small><strong className={status===undefined?'':status?'good':'quiet'}>{value}</strong></span></div>;
}
