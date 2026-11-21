import { AnimatePresence, type HTMLMotionProps, motion, useReducedMotion } from 'motion/react';
import { Children, cloneElement, forwardRef, isValidElement, type Key, type ReactElement, type ReactNode, useCallback, useImperativeHandle, useLayoutEffect, useRef, useState } from 'react';

type DynamicButtonVariant='primary'|'secondary';
export type DynamicButtonProps=Omit<HTMLMotionProps<'button'>,'animate'|'children'|'initial'|'ref'|'transition'>&{
 children?:ReactNode;
 icon?:ReactNode;
 stateKey?:Key;
 variant?:DynamicButtonVariant;
 width?:'content'|'full';
};

const easeOut=[.23,1,.32,1] as const;
const buttonClasses:Record<DynamicButtonVariant,string>={
 primary:'border-transparent bg-gradient-to-r from-violet-600 to-violet-800 text-white hover:brightness-105',
 secondary:'border-[var(--cm-border)] bg-[var(--cm-surface)] text-[var(--cm-text)] hover:bg-[var(--cm-hover)]',
};
function textSignature(value:ReactNode):string{
 return Children.toArray(value).map(child=>{
  if(typeof child==='string'||typeof child==='number')return String(child);
  if(isValidElement(child)){const props=child.props as {children?:ReactNode;title?:string};return `${props.title??''}${textSignature(props.children)}`;}
  return '';
 }).join('\u0000');
}
function animateText(value:ReactNode,path='0'):ReactNode{
 return Children.map(value,(child,index)=>{
  const key=`${path}.${index}`;
  if(typeof child==='string'||typeof child==='number'){
   if(!String(child).trim())return child;
   return <span className="dynamic-button-text" key={`${key}:${child}`}><AnimatePresence initial={false} mode="popLayout"><motion.span key={String(child)} initial={{opacity:0,y:8}} animate={{opacity:1,y:0}} exit={{opacity:0,y:-8}} transition={{duration:.18,ease:easeOut}}>{child}</motion.span></AnimatePresence></span>;
  }
  if(isValidElement(child)&&typeof child.type==='string'&&typeof child.props==='object'&&child.props!==null&&'children'in child.props){
   const element=child as ReactElement<{children?:ReactNode}>;
   return cloneElement(element,{key,children:animateText(element.props.children,key)});
  }
  return child;
 });
}

export const DynamicButton=forwardRef<HTMLButtonElement,DynamicButtonProps>(function DynamicButton({children,className='',icon,stateKey,type,variant,width='content',style,...props},forwardedRef){
 const reduceMotion=useReducedMotion();
 const buttonRef=useRef<HTMLButtonElement>(null);
 const measureRef=useRef<HTMLSpanElement>(null);
 const preserveLayoutWidth=useRef<boolean|null>(null);
 const [measuredWidth,setMeasuredWidth]=useState<number|null>(null);
 const variantFromClass:DynamicButtonVariant=className.split(/\s+/).includes('primary')?'primary':variant??'secondary';
 const signature=textSignature(children);
 const iconKey=stateKey??signature;
 const syncWidth=useCallback(()=>{
  const button=buttonRef.current,measure=measureRef.current;
  if(!button||!measure||width!=='content')return;
  const css=getComputedStyle(button),parent=button.parentElement;
  const padding=parseFloat(css.paddingLeft)+parseFloat(css.paddingRight);
  const border=parseFloat(css.borderLeftWidth)+parseFloat(css.borderRightWidth);
  const natural=Math.ceil(measure.scrollWidth+padding+border);
  if(preserveLayoutWidth.current===null){
   const parentStyle=parent?getComputedStyle(parent):null;
   const flexFill=parseFloat(css.flexGrow)>0;
   const stretches=!!parent&&button.getBoundingClientRect().width>natural+4&&(
    flexFill||Math.abs(button.getBoundingClientRect().width-parent.clientWidth)<3||
    (parentStyle?.display==='grid'&&css.alignSelf==='stretch')
   );
   preserveLayoutWidth.current=stretches||Boolean(style?.width);
  }
  if(preserveLayoutWidth.current)return;
  const minWidth=css.minWidth==='auto'?0:parseFloat(css.minWidth)||0;
  const next=Math.max(natural,minWidth);
  setMeasuredWidth(current=>current===next?current:next);
 },[style?.width,width]);
 useImperativeHandle(forwardedRef,()=>buttonRef.current as HTMLButtonElement);
 useLayoutEffect(()=>{
  const measure=measureRef.current;
  if(!measure||width!=='content')return;
  syncWidth();
  const observer=new ResizeObserver(syncWidth);
  observer.observe(measure);
  window.addEventListener('resize',syncWidth);
  return()=>{observer.disconnect();window.removeEventListener('resize',syncWidth);};
 },[syncWidth,width,signature,icon]);
 const duration=0.26;
 const shown=icon? <><span className="dynamic-button-icon"><AnimatePresence initial={false} mode="popLayout"><motion.span key={iconKey} initial={{opacity:0,y:reduceMotion?0:8}} animate={{opacity:1,y:0}} exit={{opacity:0,y:reduceMotion?0:-8}} transition={{duration:reduceMotion?0:0.18,ease:easeOut}}>{icon}</motion.span></AnimatePresence></span>{animateText(children)}</> : animateText(children);
 return <motion.button {...props} ref={buttonRef} type={type} style={style} className={[
 'dynamic-button relative min-w-0 max-w-full !whitespace-normal !break-words transition-[color,background-color,border-color,box-shadow,transform] duration-150 ease-[cubic-bezier(0.23,1,0.32,1)] active:scale-[0.97]',
  buttonClasses[variantFromClass],width==='full'?'w-full':'',className,
 ].filter(Boolean).join(' ')} animate={width==='full'||preserveLayoutWidth.current?undefined:{width:measuredWidth??'auto'}} initial={false} transition={width==='full'||preserveLayoutWidth.current?undefined:{width:reduceMotion?{duration:0}:{type:'spring',bounce:0,duration}}}>
  <span className="dynamic-button-content">{shown}</span>
  <span aria-hidden="true" className="dynamic-button-measure" ref={measureRef}>{icon&&<span className="dynamic-button-icon">{icon}</span>}{children}</span>
 </motion.button>;
});
